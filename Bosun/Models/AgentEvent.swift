import Foundation

enum AgentEvent: Sendable {
    case textDelta(String)
    case toolCallStarted(ToolCall)
    case toolResult(ToolResult)
    case usage(prompt: Int, completion: Int, cached: Int)
    case checkpoint([ChatMessage]) // <--- Сохранение контекста
    case done
    case failed(String)
}
