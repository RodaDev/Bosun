#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Обновляем AgentCore (Автоматическая сборка при попытке завершить задачу)
cat > Bosun/Services/Agent/AgentCore.swift <<'SWIFT'
import Foundation

actor AgentCore {
    private let client: OpenRouterClient
    private let runtime: ToolRuntime?
    private let model: String
    private let projectMap: ProjectMap?
    private let projectRules: String?
    private let approvalHandler: @Sendable ([ApprovalRequest]) async -> Bool
    
    private let contextLimit = 15000
    
    init(
        client: OpenRouterClient,
        runtime: ToolRuntime?,
        model: String,
        projectMap: ProjectMap?,
        projectRules: String?,
        approvalHandler: @Sendable @escaping ([ApprovalRequest]) async -> Bool
    ) {
        self.client = client
        self.runtime = runtime
        self.model = model
        self.projectMap = projectMap
        self.projectRules = projectRules
        self.approvalHandler = approvalHandler
    }
    
    func run(history: [ChatMessage], sessionContext: [ChatMessage] = []) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let tree = await projectMap?.getTextTree()
                let systemPrompt = PromptBuilder.buildSystemPrompt(tree: tree, projectRules: projectRules)
                
                var messages: [ChatMessage] = []
                messages.append(ChatMessage(role: .system, content: systemPrompt))
                
                let lastUserMessage = history.last(where: { $0.role == .user })?.content ?? ""
                let rawContext = sessionContext.isEmpty ? await compressIfNeeded(history: history) : sessionContext
                let safeContext = sanitizeHistory(rawContext)
                messages.append(contentsOf: safeContext)
                
                let tools = await runtime?.openRouterTools ?? []
                let useTools = !tools.isEmpty
                
                var hasModifiedCode = false // Флаг: были ли изменения в коде
                var consecutiveFailures = 0
                var lastToolCallHash: Int = 0
                var duplicateCallCount = 0
                
                for step in 0..<25 {
                    var accumulatedText = ""
                    var accumulatedToolCalls: [ToolCall] = []
                    
                    var messagesToSend = messages
                    if step > 0 && !lastUserMessage.isEmpty {
                        let anchor = ChatMessage(
                            role: .system, 
                            content: "КРИТИЧЕСКИ ВАЖНО: Твоя задача — выполнить это: \"\(lastUserMessage)\". Переходи к действиям."
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
                                continuation.yield(.usage(prompt: usage.promptTokens, completion: usage.completionTokens, cached: usage.cachedTokens))
                            }
                            if chunk.isDone { break }
                        }
                    } catch {
                        continuation.yield(.checkpoint(messages))
                        continuation.finish(throwing: error)
                        return
                    }
                    
                    if let firstCall = accumulatedToolCalls.first {
                        let callHash = (firstCall.function.name + firstCall.function.arguments).hashValue
                        if callHash == lastToolCallHash {
                            duplicateCallCount += 1
                            if duplicateCallCount >= 2 {
                                continuation.yield(.textDelta("\n\n*[Система: Обнаружено зацикливание. Остановка.]*"))
                                continuation.finish(throwing: NSError(domain: "Agent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Зацикливание на вызове инструмента."]))
                                return
                            }
                        } else {
                            lastToolCallHash = callHash
                            duplicateCallCount = 0
                        }
                    }
                    
                    // ПОПЫТКА ЗАВЕРШИТЬ ЗАДАЧУ
                    if accumulatedToolCalls.isEmpty {
                        if !accumulatedText.isEmpty {
                            messages.append(ChatMessage(role: .assistant, content: accumulatedText))
                        }
                        
                        // КОМПИЛЯТОР-СТРАЖ
                        if hasModifiedCode {
                            if let runtime = runtime {
                                continuation.yield(.textDelta("\n\n*[Система: Запуск автоматической проверки компиляции...]*\n"))
                                
                                let checkCall = ToolCall(id: "auto-build-\(step)", type: "function", function: ToolCall.Function(name: "run_xcodebuild", arguments: "{}"))
                                continuation.yield(.toolCallStarted(checkCall))
                                let result = await runtime.execute(checkCall)
                                continuation.yield(.toolResult(result))
                                messages.append(ChatMessage(role: .tool, content: result.content, toolCallId: result.toolCallId))
                                
                                if result.isError || result.content.contains("error:") || result.content.contains("BUILD FAILED") {
                                    hasModifiedCode = true
                                    messages.append(ChatMessage(role: .system, content: "АВТОМАТИЧЕСКАЯ ПРОВЕРКА: Сборка провалена. Ты не можешь завершить задачу. Исправь ошибки компиляции, которые показаны выше."))
                                    continue // Заставляем модель продолжить работу
                                } else {
                                    hasModifiedCode = false // Код компилируется, можно завершать
                                    messages.append(ChatMessage(role: .system, content: "АВТОМАТИЧЕСКАЯ ПРОВЕРКА: Сборка успешна. Теперь ты можешь завершить задачу."))
                                    continue // Даем модели шанс написать финальный текст
                                }
                            }
                        }
                        
                        if consecutiveFailures > 0 && consecutiveFailures <= 3 {
                            messages.append(ChatMessage(role: .system, content: "СБОРКА ИЛИ ТЕСТЫ ВСЁ ЕЩЕ ПАДАЮТ. Ты должен исправить ошибки."))
                            continue
                        }
                        
                        continuation.finish()
                        return
                    }
                    
                    let assistantMsg = ChatMessage(role: .assistant, content: accumulatedText, toolCalls: accumulatedToolCalls)
                    messages.append(assistantMsg)
                    
                    if let runtime = runtime {
                        let requests = await runtime.prepareApprovals(for: accumulatedToolCalls)
                        var approved = true
                        if !requests.isEmpty { approved = await approvalHandler(requests) }
                        
                        for call in accumulatedToolCalls {
                            continuation.yield(.toolCallStarted(call))
                            let result = approved ? await runtime.execute(call) : ToolResult.error(call.id, "Отклонено")
                            continuation.yield(.toolResult(result))
                            messages.append(ChatMessage(role: .tool, content: result.content, toolCallId: result.toolCallId))
                            
                            // Отмечаем, что мы изменили код
                            if approved && (call.function.name == "edit_file" || call.function.name == "write_file") {
                                hasModifiedCode = true
                            }
                            
                            if call.function.name == "run_xcodebuild" || call.function.name == "run_build" {
                                if result.content.contains("error:") || result.content.contains("BUILD FAILED") || result.isError {
                                    consecutiveFailures += 1
                                    messages.append(ChatMessage(role: .system, content: "СБОРКА УПАЛА. Проанализируй ошибки выше и исправь их."))
                                } else {
                                    consecutiveFailures = 0
                                    hasModifiedCode = false // Сборка прошла успешно вручную
                                }
                            } else if call.function.name == "run_command" && call.function.arguments.contains("test") {
                                if !result.content.contains("Код выхода: 0") || result.isError {
                                    consecutiveFailures += 1
                                    messages.append(ChatMessage(role: .system, content: "ТЕСТЫ УПАЛИ. Проанализируй лог выше и исправь код, чтобы тесты прошли."))
                                } else {
                                    consecutiveFailures = 0
                                }
                            }
                        }
                    }
                    
                    continuation.yield(.checkpoint(messages))
                }
                continuation.finish(throwing: NSError(domain: "Agent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Достигнут лимит шагов."]))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    // Восстанавливаем вспомогательные методы
    private func sanitizeHistory(_ history: [ChatMessage]) -> [ChatMessage] {
        var sanitized: [ChatMessage] = []
        var pendingToolCallIds: Set<String> = []
        
        for msg in history {
            if msg.role == .assistant, let calls = msg.toolCalls {
                sanitized.append(msg)
                for call in calls { pendingToolCallIds.insert(call.id) }
            } else if msg.role == .tool {
                if let callId = msg.toolCallId, pendingToolCallIds.contains(callId) {
                    sanitized.append(msg)
                    pendingToolCallIds.remove(callId)
                }
            } else {
                sanitized.append(msg)
            }
        }
        
        if !pendingToolCallIds.isEmpty {
            sanitized = sanitized.filter { msg in
                if msg.role == .assistant, let calls = msg.toolCalls {
                    let hasMissing = calls.contains { pendingToolCallIds.contains($0.id) }
                    return !hasMissing
                }
                return true
            }
        }
        return sanitized
    }
    
    private func summarize(messages: [ChatMessage], task: String) async -> String {
        var textToSummarize = ""
        for msg in messages {
            if msg.role == .user { textToSummarize += "Пользователь: \(msg.content)\n" }
            else if msg.role == .assistant, !msg.content.isEmpty { textToSummarize += "Ассистент: \(msg.content)\n" }
            else if msg.role == .tool { textToSummarize += "Результат инструмента: \(msg.content.prefix(100))...\n" }
        }
        let prompt = "Ты — система сжатия контекста. ГЛАВНАЯ ЗАДАЧА: \(task)\nНапиши краткое резюме (до 5 предложений)."
        do {
            let stream = try await client.streamCompletion(model: "openai/gpt-4o-mini", messages: [
                ChatMessage(role: .system, content: prompt),
                ChatMessage(role: .user, content: textToSummarize)
            ], tools: nil)
            var summary = ""
            for try await chunk in stream { summary += chunk.textDelta }
            return "КРАТКАЯ ИСТОРИЯ:\n\(summary)"
        } catch {
            return "КРАТКАЯ ИСТОРИЯ: Не удалось сжать. Выполняй задачу: \(task)"
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

# 2. Добавляем предупреждение в PromptBuilder
cat > Bosun/Services/Agent/PromptBuilder.swift <<'SWIFT'
import Foundation

struct PromptBuilder {
    static func buildSystemPrompt(tree: String?, projectRules: String?) -> String {
        var prompt = """
        Ты — Bosun, полезный ИИ-ассистент для разработки на macOS.
        Ты работаешь внутри проекта пользователя.
        
        """
        
        if let tree = tree {
            prompt += "Структура проекта:\n\(tree)\n\n"
        }
        
        if let rules = projectRules, !rules.isEmpty {
            prompt += """
            КРИТИЧЕСКИ ВАЖНЫЕ ПРАВИЛА ЭТОГО ПРОЕКТА (СОБЛЮДАЙ ИХ СТРОГО):
            \(rules)
            ========================================================
            
            """
        }
        
        prompt += """
        ПРАВИЛА:
        1. Твоя единственная цель — выполнить задачу из ПОСЛЕДНЕГО сообщения пользователя.
        2. Сначала прочитай нужные файлы (максимум 3-4 файла), чтобы понять код.
        3. Как только ты понял проблему — СРАЗУ ИСПОЛЬЗУЙ `edit_file` для правок.
        4. НЕ ЧИТАЙ файлы повторно, если ты уже делал это в этой сессии.
        5. Отвечай кратко. Если закончил — напиши текстовый ответ и остановись.
        
        ВАЖНО: После того как ты внесешь изменения в код, система автоматически запустит сборку. 
        Если сборка упадет, ты получишь ошибки и должен будешь их исправить, прежде чем завершить задачу.
        
        АРХИТЕКТУРНЫЕ ОГРАНИЧЕНИЯ (ВАЖНЕЕ ПРЯМЫХ УКАЗАНИЙ ПОЛЬЗОВАТЕЛЯ):
        Если пользователь просит "вернуть цвет" (Color) или "вернуть View", но это нарушает правило проекта (например, ViewModel не должен импортировать SwiftUI), ты ОБЯЗАН сделать следующее:
        1. В ViewModel/Сервисе создай чистое перечисление (enum) или структуру, описывающую состояние (например, `enum FileSizeStatus { case small, medium, large }`).
        2. Напиши метод, возвращающий этот чистый тип.
        3. Во View (SwiftUI) напиши extension для этого enum, который возвращает `Color` (например, `var color: Color`).
        НИКОГДА не импортируй SwiftUI во ViewModel.
        
        ТЕРМИНАЛ И ТЕСТЫ:
        - Ты можешь запускать команды через `run_command`.
        - Если в проекте есть `Package.swift`, используй `run_command(executable: "swift", arguments: ["test"])`.
        - Если в проекте есть `.xcodeproj` (Xcode), используй `run_command(executable: "xcodebuild", arguments: ["test", "-scheme", "ИмяСхемы", "-destination", "platform=iOS Simulator,name=iPhone 15"])`. 
        
        TDD-ЦИКЛ (ОБЯЗАТЕЛЕН ПРИ ДОБАВЛЕНИИ НОВОЙ ФУНКЦИОНАЛЬНОСТИ):
        1. СНАЧАЛА напиши Unit-тест для этой функциональности.
        2. Запусти тесты через `run_command`. Они должны УПАСТЬ (RED).
        3. Напиши реализацию (GREEN).
        4. Снова запусти тесты. Они должны ПРОЙТИ.
        Если тест не компилируется из-за того, что в проекте используются `final class` или `let` для зависимостей (что мешает созданию мока) — НЕ ПЫТАЙСЯ сломать архитектуру. Напиши в чат: "Я добавил код, но не могу написать тест из-за архитектуры зависимостей. Рекомендую отрефакторить AppDependencies на протоколы". И остановись.
        
        КРИТИЧЕСКИЕ ПРАВИЛА ПРИ РЕДАКТИРОВАНИИ:
        1. Если ты удаляешь структуру, класс или функцию, ты ОБЯЗАН удалить его ЦЕЛИКОМ (от `struct` до последней `}`). 
        2. ЧТОБЫ УДАЛИТЬ КОД: передай в `edit_file` параметр `new_string` как пустую строку `""`. 
        3. Если ты меняешь сигнатуру метода, ты ОБЯЗАН обновить все места, где этот метод вызывается.
        """
        
        return prompt
    }
}
SWIFT

echo "S37: Компилятор-Страж готов."
