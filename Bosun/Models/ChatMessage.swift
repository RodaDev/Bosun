//
//  ChatMessage.swift
//  Bosun
//
//  Created by Dmitry on 18.10.2026.
//

import Foundation

enum ChatRole: String, Codable, Sendable {
    case system, user, assistant
}

struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let role: ChatRole
    var content: String

    init(id: UUID = UUID(), role: ChatRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

extension ChatMessage {
    struct Wire: Codable, Sendable {
        let role: String
        let content: String
    }

    var wire: Wire { Wire(role: role.rawValue, content: content) }
}

struct ChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage.Wire]
    let stream: Bool
}
