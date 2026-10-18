import Foundation

actor AgentCore {
    private let client: OpenRouterClient
    private let runtime: ToolRuntime?
    private let model: String
    
    init(client: OpenRouterClient, runtime: ToolRuntime?, model: String) {
        self.client = client
        self.runtime = runtime
        self.model = model
    }
    
    func run(history: [ChatMessage]) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var messages = history
                let tools = await runtime?.openRouterTools ?? []
                let useTools = !tools.isEmpty
                
                for _ in 0..<5 {
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
                            if chunk.isDone { break }
                        }
                    } catch {
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
                    
                    for call in accumulatedToolCalls {
                        continuation.yield(.toolCallStarted(call))
                        if let runtime = runtime {
                            let result = await runtime.execute(call)
                            continuation.yield(.toolResult(result))
                            let toolMsg = ChatMessage(role: .tool, content: result.content, toolCallId: result.toolCallId)
                            messages.append(toolMsg)
                        } else {
                            let result = ToolResult.error(call.id, "Инструменты недоступны (проект не выбран)")
                            continuation.yield(.toolResult(result))
                            let toolMsg = ChatMessage(role: .tool, content: result.content, toolCallId: result.toolCallId)
                            messages.append(toolMsg)
                        }
                    }
                }
                
                continuation.finish(throwing: NSError(domain: "Agent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Превышен лимит вызовов инструментов (5)"]))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
