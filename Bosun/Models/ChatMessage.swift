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
    struct Wire: Encodable, Sendable {
        let role: String
        let content: String?
        let tool_calls: [ToolCall]?
        let tool_call_id: String?
        let imageContent: [WireContent]?
        
        enum CodingKeys: String, CodingKey {
            case role, content, tool_calls, tool_call_id
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            if let tool_calls = tool_calls { try container.encode(tool_calls, forKey: .tool_calls) }
            if let tool_call_id = tool_call_id { try container.encode(tool_call_id, forKey: .tool_call_id) }
            
            if let imageContent = imageContent, !imageContent.isEmpty {
                // Если есть картинки (только для User), отправляем массив
                try container.encode(imageContent, forKey: .content)
            } else {
                // Обычный текст отправляем строкой
                try container.encode(content ?? "", forKey: .content)
            }
        }
    }
    
    struct WireContent: Codable, Sendable {
        let type: String
        let text: String?
        let image_url: ImageURL?
        
        struct ImageURL: Codable, Sendable {
            let url: String
        }
    }

    var wire: Wire {
        var parts: [WireContent] = []
        
        if let atts = attachments {
            for att in atts {
                if att.type == .image, let b64 = att.base64Image {
                    parts.append(WireContent(type: "image_url", text: nil, image_url: .init(url: b64)))
                } else if att.type == .text, let text = att.textContent {
                    parts.append(WireContent(type: "text", text: "Содержимое файла \(att.fileName):\n\(text)\n", image_url: nil))
                }
            }
        }
        
        if !content.isEmpty {
            parts.append(WireContent(type: "text", text: content, image_url: nil))
        }
        
        // Проверяем, есть ли реальные картинки
        let hasImages = attachments?.contains(where: { $0.type == .image }) ?? false
        
        if role == .user && hasImages {
            // Если пользователь отправил картинку — используем Vision API
            return Wire(role: role.rawValue, content: nil, tool_calls: toolCalls, tool_call_id: toolCallId, imageContent: parts)
        } else {
            // Во всех остальных случаях (tool, assistant, text-only user) — отправляем строку
            let combinedText = parts.compactMap { $0.text }.joined(separator: "\n")
            return Wire(role: role.rawValue, content: combinedText, tool_calls: toolCalls, tool_call_id: toolCallId, imageContent: nil)
        }
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
