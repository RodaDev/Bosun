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
    
    func run(history: [ChatMessage], sessionContext: [ChatMessage] = [], maxIterations: Int = 25) async throws -> AsyncThrowingStream<AgentEvent, Error> {
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
                
                var hasModifiedSourceCode = false
                var hasWrittenTests = false
                var hasRunTests = false
                var consecutiveFailures = 0
                var lastToolCallHash: Int = 0
                var duplicateCallCount = 0
                
                // ИСПОЛЬЗУЕМ ПЕРЕДАННЫЙ ЛИМИТ
                for step in 0..<maxIterations {
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
                    
                    if accumulatedToolCalls.isEmpty {
                        if !accumulatedText.isEmpty {
                            messages.append(ChatMessage(role: .assistant, content: accumulatedText))
                        }
                        
                        // ПРИНУДИТЕЛЬНЫЙ TDD
                        if hasModifiedSourceCode && !hasWrittenTests {
                            messages.append(ChatMessage(role: .system, content: "Ты изменил исходный код, но не написал ни одного теста. По правилам проекта ты ОБЯЗАН написать Unit-тест. Создай файл с тестом и запусти его."))
                            continue
                        }
                        
                        if hasModifiedSourceCode && hasWrittenTests && !hasRunTests {
                            messages.append(ChatMessage(role: .system, content: "Ты написал тесты, но не запустил их. Используй `run_command`, чтобы запустить тесты и убедиться, что они проходят."))
                            continue
                        }
                        
                        // КОМПИЛЯТОР-СТРАЖ (МОЛЧАЛИВЫЙ)
                        if hasModifiedSourceCode {
                            if let runtime = runtime {
                                continuation.yield(.textDelta("\n\n*[Система: Запуск автоматической проверки компиляции...]*\n"))
                                
                                let checkCall = ToolCall(id: UUID().uuidString, type: "function", function: ToolCall.Function(name: "run_xcodebuild", arguments: "{}"))
                                continuation.yield(.toolCallStarted(checkCall))
                                let result = await runtime.execute(checkCall)
                                continuation.yield(.toolResult(result))
                                
                                if result.isError || result.content.contains("error:") || result.content.contains("BUILD FAILED") {
                                    // Если упало, добавляем в историю, чтобы модель исправила
                                    messages.append(ChatMessage(role: .assistant, content: "Запускаю сборку для проверки...", toolCalls: [checkCall]))
                                    messages.append(ChatMessage(role: .tool, content: result.content, toolCallId: checkCall.id))
                                    messages.append(ChatMessage(role: .system, content: "СБОРКА ПРОВАЛЕНА. Исправь ошибки компиляции, которые показаны выше."))
                                    continue
                                } else {
                                    // Если успешно — просто завершаем
                                    messages.append(ChatMessage(role: .system, content: "Сборка прошла успешно."))
                                    continuation.finish()
                                    return
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
                            
                            if approved && (call.function.name == "edit_file" || call.function.name == "write_file") {
                                if call.function.arguments.contains("Tests/") || call.function.arguments.contains("Tests.swift") {
                                    hasWrittenTests = true
                                } else if call.function.arguments.contains(".swift") {
                                    hasModifiedSourceCode = true
                                }
                            }
                            
                            if call.function.name == "run_command" && call.function.arguments.contains("test") {
                                hasRunTests = true
                                if !result.content.contains("Код выхода: 0") || result.isError {
                                    consecutiveFailures += 1
                                    messages.append(ChatMessage(role: .system, content: "ТЕСТЫ УПАЛИ. Исправь код."))
                                } else {
                                    consecutiveFailures = 0
                                }
                            }
                            
                            if call.function.name == "run_xcodebuild" || call.function.name == "run_build" {
                                if result.content.contains("error:") || result.content.contains("BUILD FAILED") || result.isError {
                                    consecutiveFailures += 1
                                    messages.append(ChatMessage(role: .system, content: "СБОРКА УПАЛА. Исправь ошибки."))
                                } else {
                                    consecutiveFailures = 0
                                }
                            }
                        }
                    }
                    
                    continuation.yield(.checkpoint(messages))
                }
                continuation.finish(throwing: NSError(domain: "Agent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Достигнут лимит шагов (\(maxIterations))."]))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    // MARK: - Helpers
    
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
