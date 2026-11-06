#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Улучшаем суммаризатор и якорь в AgentCore
cat > Bosun/Services/Agent/AgentCore.swift <<'SWIFT'
import Foundation

actor AgentCore {
    private let client: OpenRouterClient
    private let runtime: ToolRuntime?
    private let model: String
    private let projectMap: ProjectMap?
    private let approvalHandler: @Sendable ([ApprovalRequest]) async -> Bool
    
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
                var currentTokens = 0
                
                // Находим задачу пользователя
                let lastUserMessage = history.last(where: { $0.role == .user })?.content ?? ""
                
                // Если есть сохраненный контекст, добавляем его. Если нет — берем историю.
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
                    
                    var messagesToSend = messages
                    
                    // ПРОМПТ-ЯКОРЬ: Жестко напоминаем модель, в чем ее задача
                    if step > 0 && !lastUserMessage.isEmpty {
                        let anchor = ChatMessage(
                            role: .system, 
                            content: "КРИТИЧЕСКИ ВАЖНО: Твоя задача — выполнить это: \"\(lastUserMessage)\". Ты уже прочитал нужные файлы. Теперь переходи к редактированию (edit_file). Не читай файлы повторно."
                        )
                        messagesToSend.append(anchor)
                    }
                    
                    do {
                        let stream = try await client.streamCompletion(
                            model: model, 
                            messages: messagesToSend, 
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
                                currentTokens = usage.promptTokens
                                continuation.yield(.usage(prompt: usage.promptTokens, completion: usage.completionTokens, cached: usage.cachedTokens))
                            }
                            if chunk.isDone { break }
                        }
                    } catch {
                        continuation.yield(.checkpoint(messages))
                        continuation.finish(throwing: error)
                        return
                    }
                    
                    if currentTokens > contextLimit {
                        continuation.yield(.textDelta("\n\n*[Система: Контекст достиг лимита, выполняется сжатие истории...]*\n\n"))
                        
                        // Сохраняем задачу пользователя в сводке
                        let summary = await summarize(messages: messages, task: lastUserMessage)
                        let summaryMsg = ChatMessage(role: .system, content: summary)
                        
                        // Оставляем только системный промпт, сводку и последние 2 сообщения
                        let recent = Array(messages.suffix(2))
                        messages = [messages[0]] + [summaryMsg] + recent
                        currentTokens = 0
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
    
    private func summarize(messages: [ChatMessage], task: String) async -> String {
        var textToSummarize = ""
        for msg in messages {
            if msg.role == .user { textToSummarize += "Пользователь: \(msg.content)\n" }
            else if msg.role == .assistant, !msg.content.isEmpty { textToSummarize += "Ассистент: \(msg.content)\n" }
            else if msg.role == .tool { textToSummarize += "Результат инструмента: \(msg.content.prefix(100))...\n" }
        }
        
        let prompt = """
        Ты — система сжатия контекста. Твоя задача — сохранить нить рассуждений агента.
        ГЛАВНАЯ ЗАДАЧА ПОЛЬЗОВАТЕЛЯ: \(task)
        
        Напиши краткое резюме (до 5 предложений): какие файлы прочитаны, какие изменения внесены, и на каком шаге мы находимся.
        """
        
        do {
            let stream = try await client.streamCompletion(model: "openai/gpt-4o-mini", messages: [
                ChatMessage(role: .system, content: prompt),
                ChatMessage(role: .user, content: textToSummarize)
            ], tools: nil)
            var summary = ""
            for try await chunk in stream { summary += chunk.textDelta }
            return "КРАТКАЯ ИСТОРИЯ:\n\(summary)"
        } catch {
            return "КРАТКАЯ ИСТОРИЯ: Не удалось сжать контекст. Выполняй задачу: \(task)"
        }
    }
    
    private func compressIfNeeded(history: [ChatMessage]) async -> [ChatMessage] {
        if history.count <= 15 { return history }
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

# 2. Улучшаем PromptBuilder
cat > Bosun/Services/Agent/PromptBuilder.swift <<'SWIFT'
import Foundation

struct PromptBuilder {
    static func buildSystemPrompt(tree: String?) -> String {
        var prompt = """
        Ты — Bosun, полезный ИИ-ассистент для разработки на macOS.
        Ты работаешь внутри проекта пользователя.
        
        """
        
        if let tree = tree {
            prompt += "Структура проекта:\n\(tree)\n\n"
        }
        
        prompt += """
        ПРАВИЛА:
        1. Твоя единственная цель — выполнить задачу из ПОСЛЕДНЕГО сообщения пользователя.
        2. Сначала прочитай нужные файлы (максимум 3-4 файла), чтобы понять код.
        3. Как только ты понял проблему — СРАЗУ ИСПОЛЬЗУЙ `edit_file` для правок.
        4. НЕ ЧИТАЙ файлы повторно, если ты уже делал это в этой сессии.
        5. Отвечай кратко. Если закончил — напиши текстовый ответ и остановись.
        """
        
        return prompt
    }
}
SWIFT

# 3. Делаем ReadFileTool ленивым (Lazy Read)
cat > Bosun/Services/Tools/ReadOnly/ReadFileTool.swift <<'SWIFT'
import Foundation

struct ReadFileTool: AgentTool {
    let sandbox: Sandbox
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "read_file",
            description: "Читает содержимое файла. По умолчанию отдает только первые 100 строк для экономии контекста. Используй start_line для чтения остального.",
            parameters: [
                "path": ToolParameter(description: "Относительный путь к файлу"),
                "start_line": ToolParameter(type: "integer", description: "С какой строки начать (опционально)")
            ]
        )
    }
    
    struct Args: Decodable {
        let path: String
        let start_line: Int?
    }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let url = try await sandbox.resolve(args.path)
        try await sandbox.validateExists(url)
        
        let data = try Data(contentsOf: url)
        if data.count > 256 * 1024 {
            let string = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
            return string + "\n\n...[ФАЙЛ УСЕЧЕН: превышен лимит в 256 КБ]..."
        }
        
        guard let content = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Tool", code: 0, userInfo: [NSLocalizedDescriptionKey: "Файл не в кодировке UTF-8"])
        }
        
        let lines = content.components(separatedBy: .newlines)
        let start = max(0, (args.start_line ?? 1) - 1)
        let totalLines = lines.count
        
        if start >= totalLines { return "(начало за пределами файла)" }
        
        // ЛЕНИВОЕ ЧТЕНИЕ: по умолчанию отдаем только 100 строк
        let end = min(totalLines, start + 100)
        let slice = lines[start..<end]
        
        var result = slice.enumerated().map { "\(start + $0.offset + 1): \($0.element)" }.joined(separator: "\n")
        
        if end < totalLines {
            result += "\n...[УСЕЧЕНО: показано 100 строк из \(totalLines). Для продолжения используй start_line: \(end + 1)]"
        }
        
        return result
    }
}
SWIFT

echo "S12: Anti-Amnesia и Lazy Reading готовы."
