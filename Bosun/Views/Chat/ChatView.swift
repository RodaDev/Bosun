import SwiftUI

struct ChatView: View {
    @Bindable var vm: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("S0 — каркас. Здесь будет чат.")
                .foregroundStyle(.secondary)
            Spacer()
            Divider()
            TextField("Сообщение агенту…", text: $vm.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(12)
                .disabled(vm.isRunning)
        }
    }
}
