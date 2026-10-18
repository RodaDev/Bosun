//
//  MessageBubble.swift
//  Bosun
//
//  Created by Dmitry on 18.10.2026.
//

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.content)
                .textSelection(.enabled)
                .padding(10)
                .background(background)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var background: some ShapeStyle {
        message.role == .user
            ? AnyShapeStyle(Color.accentColor.opacity(0.15))
            : AnyShapeStyle(Color.secondary.opacity(0.12))
    }
    private var foreground: Color { .primary }
}
