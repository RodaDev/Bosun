import Foundation

struct ToolCall: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let type: String
    let function: Function

    struct Function: Hashable, Codable, Sendable {
        let name: String
        let arguments: String
    }
}
