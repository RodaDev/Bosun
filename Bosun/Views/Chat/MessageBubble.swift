import SwiftUI
import AppKit

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                // Вложения
                if let atts = message.attachments {
                    ForEach(atts) { att in
                        if att.type == .image, let nsImage = NSImage(data: att.data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 300, maxHeight: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            HStack {
                                Image(systemName: "doc.text")
                                Text(att.fileName)
                            }
                            .font(.caption)
                            .padding(6)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                
                // Текст
                if !message.content.isEmpty {
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(background)
                        .foregroundStyle(foreground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            
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
