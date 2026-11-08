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
                
                var consecutiveBuildFailures = 0
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
                    
                    if accumulatedToolCalls.isEmpty {
                        if !accumulatedText.isEmpty {
                            messages.append(ChatMessage(role: .assistant, content: accumulatedText))
                        }
                        if consecutiveBuildFailures > 0 && consecutiveBuildFailures <= 3 {
                            messages.append(ChatMessage(role: .system, content: "СБОРКА ВСЁ ЕЩЕ ПАДАЕТ. Исправь ошибки."))
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
                            
                            if call.function.name == "run_xcodebuild" || call.function.name == "run_build" {
                                if result.content.contains("error:") || result.content.contains("BUILD FAILED") || result.isError {
                                    consecutiveBuildFailures += 1
                                    messages.append(ChatMessage(role: .system, content: "СБОРКА УПАЛА. Проанализируй ошибки выше и исправь их."))
                                } else {
                                    consecutiveBuildFailures = 0
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
