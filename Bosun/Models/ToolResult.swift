import Foundation

struct ToolResult: Hashable, Sendable {
    let toolCallId: String
    let content: String
    let isError: Bool

    static func error(_ id: String, _ message: String) -> ToolResult {
        ToolResult(toolCallId: id, content: message, isError: true)
    }
}
