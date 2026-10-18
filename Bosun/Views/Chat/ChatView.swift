import SwiftUI

struct ChatView: View {
    @Bindable var vm: ChatViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.messages) { MessageBubble(message: $0).id($0.id) }
                        
                        // Активные вызовы
                        ForEach(vm.activeToolCalls) { call in
                            ToolCallCard(call: call, result: nil)
                        }
                        
                        // Завершенные вызовы
                        ForEach(vm.completedToolCalls, id: \.toolCallId) { res in
                            // (В реальном проекте мы бы связали call и result по id, 
                            // здесь для простоты покажем заглушку, если не нашли call)
                            if let call = vm.messages.last(where: { $0.toolCalls?.contains(where: { $0.id == res.toolCallId }) == true })?.toolCalls?.first(where: { $0.id == res.toolCallId }) {
                                ToolCallCard(call: call, result: res)
                            }
                        }

                        if !vm.streamingText.isEmpty {
                            MessageBubble(message: ChatMessage(role: .assistant, content: vm.streamingText))
                                .id("stream")
                        }
                        
                        if let err = vm.error {
                            Text(err).foregroundStyle(.red).font(.callout)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: vm.messages.count) { _, _ in
                    if let last = vm.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: vm.streamingText) { _, _ in
                    proxy.scrollTo("stream", anchor: .bottom)
                }
            }
            
            Divider()
            
            if env.projectRoot == nil {
                Text("Выберите проект слева, чтобы агент мог использовать инструменты.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }

            Composer(vm: vm, env: env)
        }
    }
}
