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
    
    init(title: String = "Новый чат") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.lastModified = Date()
        self.messages = []
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
    }
    
    func toChatMessage() -> ChatMessage {
        var calls: [ToolCall]? = nil
        if let json = toolCallsJson, let data = json.data(using: .utf8) {
            calls = try? JSONDecoder().decode([ToolCall].self, from: data)
        }
        return ChatMessage(
            id: id,
            role: ChatRole(rawValue: role) ?? .user,
            content: content,
            toolCalls: calls,
            toolCallId: toolCallId
        )
    }
}
