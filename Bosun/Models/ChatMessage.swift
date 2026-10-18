import Foundation

enum ChatRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let role: ChatRole
    var content: String
    var toolCalls: [ToolCall]?
    var toolCallId: String?

    init(id: UUID = UUID(), role: ChatRole, content: String, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

extension ChatMessage {
    struct Wire: Codable, Sendable {
        let role: String
        let content: String?
        let tool_calls: [ToolCall]?
        let tool_call_id: String?
    }

    var wire: Wire {
        Wire(role: role.rawValue, content: content.isEmpty ? nil : content, tool_calls: toolCalls, tool_call_id: toolCallId)
    }
}

struct ChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage.Wire]
    let stream: Bool
    let tools: [AnyCodable]?
}

// Хак для кодирования словаря [String: Any] в Encodable
struct AnyCodable: Encodable, Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? String { try container.encode(v) }
        else if let v = value as? Int { try container.encode(v) }
        else if let v = value as? Bool { try container.encode(v) }
        else if let v = value as? [String: Any] {
            try container.encode(v.mapValues { AnyCodable($0) })
        }
        else if let v = value as? [Any] {
            try container.encode(v.map { AnyCodable($0) })
        }
        else { try container.encodeNil() }
    }
}
