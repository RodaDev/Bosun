import SwiftUI

struct ChatView: View {
    @Bindable var vm: ChatViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                            
                            // Отрисовываем карточки инструментов
                            if let calls = msg.toolCalls {
                                ForEach(calls) { call in
                                    // Ищем результат для этого вызова
                                    if let res = vm.completedToolCalls.first(where: { $0.toolCallId == call.id }) {
                                        ToolCallCard(call: call, result: res)
                                    } else {
                                        ToolCallCard(call: call, result: nil)
                                    }
                                }
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
                    if let last = vm.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
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
        .sheet(isPresented: .init(get: { !vm.pendingApprovals.isEmpty }, set: { _ in })) {
            ApprovalSheet(
                requests: vm.pendingApprovals,
                onApprove: { allowSession in vm.resolveApproval(approved: true, allowSession: allowSession) },
                onReject: { vm.resolveApproval(approved: false) }
            )
        }
    }
}
