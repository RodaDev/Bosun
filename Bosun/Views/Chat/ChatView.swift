import SwiftUI

struct ChatView: View {
    @Bindable var vm: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.messages) { MessageBubble(message: $0).id($0.id) }
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
            if let stats = vm.cacheStats {
                HStack {
                    Text("prompt: \(stats.promptTokens) · cached: \(stats.cachedTokens) · completion: \(stats.completionTokens)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 12)
            }
            Divider()
            Composer(vm: vm)
        }
    }
}
