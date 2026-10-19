#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Обновляем PromptBuilder (добавляем промпт для суммаризации)
cat > Bosun/Services/Agent/PromptBuilder.swift <<'SWIFT'
import Foundation

struct PromptBuilder {
    static func buildSystemPrompt(tree: String?) -> String {
        var prompt = """
        Ты — Bosun, полезный ИИ-ассистент для разработки на macOS.
        Ты работаешь внутри проекта пользователя.
        
        """
        
        if let tree = tree {
            prompt += """
            Структура проекта:
            \(tree)
            
            """
        }
        
        prompt += """
        У тебя есть инструменты для чтения файлов и поиска по коду.
        ВАЖНО: Если тебе нужно изменить или прочитать несколько файлов, 
        вызывай инструменты ПАРАЛЛЕЛЬНО (в одном сообщении). 
        Не жди результата первого вызова, чтобы сделать второй, если они независимы.
        
        Всегда проверяй код перед тем, как предлагать изменения.
        Отвечай кратко и по делу.
        
        ВАЖНО: Отвечай ТОЛЬКО на самое последнее сообщение пользователя. 
        Не повторяй предыдущие ответы и не выполняй старые задачи, если тебя об этом не просили.
        """
        
        return prompt
    }
    
    static func buildSummaryPrompt() -> String {
        return """
        Ты — система сжатия контекста для ИИ-агента.
        Прочитай следующий диалог агента и пользователя.
        Напиши краткое резюме (не более 5 предложений), в котором укажи:
        1. Какова была изначальная цель пользователя.
        2. Какие файлы были прочитаны или изменены.
        3. Какие шаги уже выполнены.
        4. Что осталось сделать (если не закончено).
        Не пиши лишнего. Только сухие факты для памяти агента.
        """
    }
}
SWIFT

# 2. Обновляем AgentCore (Внедряем настоящую суммаризацию)
cat > Bosun/Services/Agent/AgentCore.swift <<'SWIFT'
import Foundation

actor AgentCore {
    private let client: OpenRouterClient
    private let runtime: ToolRuntime?
    private let model: String
    private let projectMap: ProjectMap?
    private let approvalHandler: @Sendable ([ApprovalRequest]) async -> Bool
    
    // Порог токенов, после которого запускается сжатие
    private let contextLimit = 15000
    
    init(
        client: OpenRouterClient,
        runtime: ToolRuntime?,
        model: String,
        projectMap: ProjectMap?,
        approvalHandler: @Sendable @escaping ([ApprovalRequest]) async -> Bool
    ) {
        self.client = client
        self.runtime = runtime
        self.model = model
        self.projectMap = projectMap
        self.approvalHandler = approvalHandler
    }
    
    func run(history: [ChatMessage], sessionContext: [ChatMessage] = []) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let tree = await projectMap?.getTextTree()
                let systemPrompt = PromptBuilder.buildSystemPrompt(tree: tree)
                
                var messages: [ChatMessage] = []
                messages.append(ChatMessage(role: .system, content: systemPrompt))
                
                var currentContext = sessionContext
                var currentTokens = 0 // Примерный счетчик
                
                if !currentContext.isEmpty {
                    messages.append(contentsOf: currentContext)
                } else {
                    let contextToSend = await compressIfNeeded(history: history)
                    messages.append(contentsOf: contextToSend)
                }
                
                let tools = await runtime?.openRouterTools ?? []
                let useTools = !tools.isEmpty
                
                for step in 0..<25 {
                    var accumulatedText = ""
                    var accumulatedToolCalls: [ToolCall] = []
                    
                    do {
                        let stream = try await client.streamCompletion(
                            model: model, 
                            messages: messages, 
                            tools: useTools ? tools : nil
                        )
                        
                        for try await chunk in stream {
                            if !chunk.textDelta.isEmpty {
                                accumulatedText += chunk.textDelta
                                continuation.yield(.textDelta(chunk.textDelta))
                            }
                            if let tcs = chunk.toolCalls {
                                accumulatedToolCalls.append(contentsOf: tcs)
                            }
                            if let usage = chunk.usage {
                                currentTokens = usage.promptTokens // Обновляем счетчик
                                continuation.yield(.usage(prompt: usage.promptTokens, completion: usage.completionTokens, cached: usage.cachedTokens))
                            }
                            if chunk.isDone { break }
                        }
                    } catch {
                        continuation.yield(.checkpoint(messages))
                        continuation.finish(throwing: error)
                        return
                    }
                    
                    // Если токенов слишком много, запускаем сжатие
                    if currentTokens > contextLimit {
                        continuation.yield(.textDelta("\n\n*[Система: Контекст достиг лимита, выполняется сжатие истории...]*\n\n"))
                        
                        // Берем последние 4 сообщения, остальное сжимаем
                        let recent = Array(messages.suffix(4))
                        let toSummarize = Array(messages.dropLast(4).dropFirst()) // без системного промпта
                        
                        let summary = await summarize(messages: toSummarize)
                        let summaryMsg = ChatMessage(role: .system, content: "КРАТКАЯ ИСТОРИЯ ПРЕДЫДУЩИХ ДЕЙСТВИЙ:\n\(summary)")
                        
                        // Пересобираем контекст
                        messages = [messages[0]] + [summaryMsg] + recent
                        currentTokens = 0 // Сбрасываем счетчик (примерно)
                        
                        continuation.yield(.checkpoint(messages))
                    }
                    
                    if accumulatedToolCalls.isEmpty {
                        if !accumulatedText.isEmpty {
                            messages.append(ChatMessage(role: .assistant, content: accumulatedText))
                        }
                        continuation.finish()
                        return
                    }
                    
                    let assistantMsg = ChatMessage(role: .assistant, content: accumulatedText, toolCalls: accumulatedToolCalls)
                    messages.append(assistantMsg)
                    
                    if let runtime = runtime {
                        let requests = await runtime.prepareApprovals(for: accumulatedToolCalls)
                        var approved = true
                        
                        if !requests.isEmpty {
                            approved = await approvalHandler(requests)
                        }
                        
                        for call in accumulatedToolCalls {
                            continuation.yield(.toolCallStarted(call))
                            let result: ToolResult
                            if approved {
                                result = await runtime.execute(call)
                            } else {
                                result = ToolResult.error(call.id, "Пользователь отклонил изменения.")
                            }
                            
                            continuation.yield(.toolResult(result))
                            messages.append(ChatMessage(role: .tool, content: result.content, toolCallId: result.toolCallId))
                        }
                    } else {
                        for call in accumulatedToolCalls {
                            continuation.yield(.toolCallStarted(call))
                            let result = ToolResult.error(call.id, "Инструменты недоступны")
                            continuation.yield(.toolResult(result))
                            messages.append(ChatMessage(role: .tool, content: result.content, toolCallId: result.toolCallId))
                        }
                    }
                    
                    continuation.yield(.checkpoint(messages))
                }
                
                continuation.finish(throwing: NSError(domain: "Agent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Достигнут лимит шагов (25)."]))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    // Настоящее сжатие через дешевую модель
    private func summarize(messages: [ChatMessage]) async -> String {
        var textToSummarize = ""
        for msg in messages {
            if msg.role == .user {
                textToSummarize += "Пользователь: \(msg.content)\n"
            } else if msg.role == .assistant, !msg.content.isEmpty {
                textToSummarize += "Ассистент: \(msg.content)\n"
            } else if msg.role == .tool {
                textToSummarize += "Результат инструмента: \(msg.content.prefix(200))...\n"
            }
        }
        
        let summaryRequest = ChatCompletionRequest(
            model: "openai/gpt-4o-mini", // Используем дешевую и быструю модель для сжатия
            messages: [
                ChatMessage(role: .system, content: PromptBuilder.buildSummaryPrompt()).wire,
                ChatMessage(role: .user, content: textToSummarize).wire
            ],
            stream: false,
            tools: nil
        )
        
        do {
            // Мы используем тот же клиент, но не стриминговый метод
            // В идеале нужно добавить метод non-streaming completion в OpenRouterClient
            // Пока для простоты используем стриминговый и собираем текст
            let stream = try await client.streamCompletion(model: "openai/gpt-4o-mini", messages: summaryRequest.messages.map { ChatMessage(role: ChatRole(rawValue: $0.role) ?? .user, content: $0.content ?? "") }, tools: nil)
            var summary = ""
            for try await chunk in stream {
                summary += chunk.textDelta
            }
            return summary.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Не удалось сжать контекст из-за ошибки сети."
        }
    }
    
    private func compressIfNeeded(history: [ChatMessage]) async -> [ChatMessage] {
        if history.count <= 15 { return history }
        // Простая обрезка для первичной отправки
        let toSummarize = Array(history.prefix(history.count - 5))
        let recent = Array(history.suffix(5))
        
        var summaryText = "Краткая сводка предыдущих действий:\n"
        for msg in toSummarize {
            if msg.role == .user { summaryText += "- Пользователь: \(msg.content.prefix(100))\n" }
            else if msg.role == .assistant, !msg.content.isEmpty { summaryText += "- Ассистент: \(msg.content.prefix(100))\n" }
            else if msg.role == .tool { summaryText += "- Инструмент выполнен.\n" }
        }
        return [ChatMessage(role: .system, content: summaryText)] + recent
    }
}
SWIFT

echo "S8: Smart Context Compaction готов."
