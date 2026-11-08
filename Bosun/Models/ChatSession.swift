import Foundation
import SwiftData

@Model
final class ChatSession {
    var id: UUID
    var title: String
    var createdAt: Date
    var lastModified: Date
    
    @Relationship(deleteRule: .cascade, inverse: \StoredMessage.session)
    var messages: [StoredMessage]
    
    init(title: String = "Новый диалог") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.lastModified = Date()
        self.messages = []
    }
    
    var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastModified, relativeTo: Date())
    }
}

@Model
final class StoredMessage {
    var id: UUID
    var role: String
    var content: String
    var toolCallsJson: String?
    var toolCallId: String?
    var timestamp: Date
    var attachmentsJson: String? // <-- Храним вложения в JSON
    
    var session: ChatSession?
    
    init(from chatMessage: ChatMessage) {
        self.id = chatMessage.id
        self.role = chatMessage.role.rawValue
        self.content = chatMessage.content
        self.toolCallId = chatMessage.toolCallId
        self.timestamp = Date()
        
        if let calls = chatMessage.toolCalls, let data = try? JSONEncoder().encode(calls) {
            self.toolCallsJson = String(data: data, encoding: .utf8)
        }
        if let atts = chatMessage.attachments, let data = try? JSONEncoder().encode(atts) {
            self.attachmentsJson = String(data: data, encoding: .utf8)
        }
    }
    
    func toChatMessage() -> ChatMessage {
        var calls: [ToolCall]? = nil
        if let json = toolCallsJson, let data = json.data(using: .utf8) {
            calls = try? JSONDecoder().decode([ToolCall].self, from: data)
        }
        var atts: [ChatAttachment]? = nil
        if let json = attachmentsJson, let data = json.data(using: .utf8) {
            atts = try? JSONDecoder().decode([ChatAttachment].self, from: data)
        }
        return ChatMessage(
            id: id,
            role: ChatRole(rawValue: role) ?? .user,
            content: content,
            toolCalls: calls,
            toolCallId: toolCallId,
            attachments: atts
        )
    }
}
