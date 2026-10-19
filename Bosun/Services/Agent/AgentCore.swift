import Foundation

actor AgentCore {
    private let client: OpenRouterClient
    private let runtime: ToolRuntime?
    private let model: String
    private let projectMap: ProjectMap?
    private let approvalHandler: @Sendable ([ApprovalRequest]) async -> Bool
    
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
    
    // Основной цикл
    func run(history: [ChatMessage], sessionContext: [ChatMessage] = []) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let tree = await projectMap?.getTextTree()
                let systemPrompt = PromptBuilder.buildSystemPrompt(tree: tree)
                
                var messages: [ChatMessage] = []
                messages.append(ChatMessage(role: .system, content: systemPrompt))
                
                // Если есть сохраненный контекст сессии (после сбоя), используем его
                if !sessionContext.isEmpty {
                    messages.append(contentsOf: sessionContext)
                } else {
                    // Иначе берем историю UI (сжимаем, если она слишком длинная)
                    let contextToSend = await compressIfNeeded(history: history)
                    messages.append(contentsOf: contextToSend)
                }
                
                let tools = await runtime?.openRouterTools ?? []
                let useTools = !tools.isEmpty
                
                // Динамический лимит: 25 шагов
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
                                continuation.yield(.usage(prompt: usage.promptTokens, completion: usage.completionTokens, cached: usage.cachedTokens))
                            }
                            if chunk.isDone { break }
                        }
                    } catch {
                        // В случае ошибки (например, таймаута) сохраняем контекст
                        continuation.yield(.checkpoint(messages))
                        continuation.finish(throwing: error)
                        return
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
                    
                    // Сохраняем контекст после каждого успешного шага
                    continuation.yield(.checkpoint(messages))
                    
                    // Защита от зацикливания (если агент 25 раз вызывает один и тот же инструмент)
                    if step == 24 {
                        continuation.yield(.checkpoint(messages))
                        continuation.finish(throwing: NSError(domain: "Agent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Достигнут лимит шагов (25). Вы можете продолжить диалог."]))
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    // Сжатие контекста, если история слишком длинная
    private func compressIfNeeded(history: [ChatMessage]) async -> [ChatMessage] {
        if history.count <= 15 {
            return history
        }
        
        // Берем последние 5 сообщений, остальные суммируем
        let toSummarize = Array(history.prefix(history.count - 5))
        let recent = Array(history.suffix(5))
        
        var summaryText = "Краткая сводка предыдущих действий:\n"
        for msg in toSummarize {
            if msg.role == .user {
                summaryText += "- Пользователь: \(msg.content.prefix(100))\n"
            } else if msg.role == .assistant, !msg.content.isEmpty {
                summaryText += "- Ассистент: \(msg.content.prefix(100))\n"
            } else if msg.role == .tool {
                summaryText += "- Инструмент выполнен.\n"
            }
        }
        
        let summaryMsg = ChatMessage(role: .system, content: summaryText)
        return [summaryMsg] + recent
    }
}
