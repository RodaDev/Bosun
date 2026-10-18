import SwiftUI

struct ProjectTreeView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            if env.projectRoot != nil {
                List(env.chatVM.projectNodes, children: \.children) { node in
                    HStack(spacing: 6) {
                        Image(systemName: node.isDirectory ? "folder" : "doc.text")
                            .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                        Text(node.name)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(node.isModified ? .orange : .primary)
                    }
                }
                .listStyle(.sidebar)
            } else {
                Spacer()
                Text("Проект не выбран")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            
            Divider()
            
            // Плашка с токенами и балансом
            VStack(alignment: .leading, spacing: 6) {
                // Баланс
                HStack {
                    Text("Баланс:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let bal = env.chatVM.remainingBalance {
                        Text(String(format: "$%.4f", bal))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(bal > 0 ? .green : .red)
                    } else {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Divider()
                
                // Токены
                Text("Токены (сессия)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "arrow.up.circle")
                    Text("\(env.chatVM.totalPromptTokens)")
                    Spacer()
                    Image(systemName: "arrow.down.circle")
                    Text("\(env.chatVM.totalCompletionTokens)")
                }
                .font(.system(.caption, design: .monospaced))
            }
            .padding(10)
            .background(Color.black.opacity(0.1))
        }
        .onAppear {
            Task {
                await env.chatVM.loadTree(from: env.projectMap)
                await env.chatVM.refreshBalance()
            }
        }
    }
}
