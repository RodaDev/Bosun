import SwiftUI
import AppKit

struct ChatView: View {
    @Bindable var vm: ChatViewModel
    @Environment(AppEnvironment.self) private var env
    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 0) {
            // Верхняя панель (Toolbar)
            HStack {
                Text(env.projectRoot?.lastPathComponent ?? "Проект не выбран")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    isRefreshing = true
                    Task {
                        _ = await env.projectMap?.refreshTree()
                        await vm.loadTree(from: env.projectMap)
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("Обновить карту проекта")
                
                Button {
                    selectFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Сменить проект")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.messages) { msg in
                            if !msg.content.isEmpty {
                                MessageBubble(message: msg).id(msg.id)
                            }
                            if let calls = msg.toolCalls {
                                ForEach(calls) { call in
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
                    if let last = vm.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: vm.streamingText) { _, _ in
                    proxy.scrollTo("stream", anchor: .bottom)
                }
            }
            
            Divider()
            
            if env.projectRoot == nil {
                Text("Выберите проект, чтобы агент мог использовать инструменты.")
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
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            env.projectRoot = url
            Task { await vm.loadTree(from: env.projectMap) }
        }
    }
}
