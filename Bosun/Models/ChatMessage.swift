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
    var attachments: [ChatAttachment]?

    init(id: UUID = UUID(), role: ChatRole, content: String, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil, attachments: [ChatAttachment]? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.attachments = attachments
    }
}

extension ChatMessage {
    struct Wire: Codable, Sendable {
        let role: String
        let content: [WireContent]?
        let tool_calls: [ToolCall]?
        let tool_call_id: String?
    }
    
    struct WireContent: Codable, Sendable {
        let type: String // "text" or "image_url"
        let text: String?
        let image_url: ImageURL?
        
        struct ImageURL: Codable, Sendable {
            let url: String
        }
    }

    var wire: Wire {
        var parts: [WireContent] = []
        
        // 1. Добавляем вложения (картинки и текст)
        if let atts = attachments {
            for att in atts {
                if att.type == .image, let b64 = att.base64Image {
                    parts.append(WireContent(type: "image_url", text: nil, image_url: .init(url: b64)))
                } else if att.type == .text, let text = att.textContent {
                    parts.append(WireContent(type: "text", text: "Содержимое файла \(att.fileName):\n\(text)\n", image_url: nil))
                }
            }
        }
        
        // 2. Добавляем обычный текст сообщения
        if !content.isEmpty {
            parts.append(WireContent(type: "text", text: content, image_url: nil))
        }
        
        return Wire(
            role: role.rawValue, 
            content: parts.isEmpty ? nil : parts, 
            tool_calls: toolCalls, 
            tool_call_id: toolCallId
        )
    }
}

struct ChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage.Wire]
    let stream: Bool
    let tools: [AnyCodable]?
}

struct AnyCodable: Encodable, Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? String { try container.encode(v) }
        else if let v = value as? Int { try container.encode(v) }
        else if let v = value as? Bool { try container.encode(v) }
        else if let v = value as? [String: Any] { try container.encode(v.mapValues { AnyCodable($0) }) }
        else if let v = value as? [Any] { try container.encode(v.map { AnyCodable($0) }) }
        else { try container.encodeNil() }
    }
}
