import SwiftUI
import SwiftData

struct ProjectTreeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(spacing: 0) {
            if env.projectRoot != nil {
                List(env.chatVM.projectNodes, children: \.children) { node in
                    HStack(spacing: 6) {
                        Image(systemName: node.isDirectory ? "folder" : "doc.text")
                            .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                        Text(node.name).font(.system(.body, design: .monospaced))
                    }
                }
                .listStyle(.sidebar)
            } else {
                Spacer()
                Text("Проект не выбран").foregroundStyle(.secondary)
                Spacer()
            }
            
            Divider()
            
            // БЛОК ИНДЕКСАЦИИ
            VStack(alignment: .leading, spacing: 6) {
                switch env.indexState.status {
                case .indexing(let msg):
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Индексация...").font(.caption).bold()
                    }
                    Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    
                case .indexed(let date):
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("База знаний готова").font(.caption).bold()
                    }
                    Text("Обновлено: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("Обновить индекс") {
                        Task { await env.startIndexing() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    
                case .error(let msg):
                    HStack {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text("Ошибка индексации").font(.caption).bold()
                    }
                    Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(2)
                    Button("Повторить") {
                        Task { await env.startIndexing() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    
                case .notIndexed:
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Не проиндексирован").font(.caption).bold()
                    }
                    Button("Проиндексировать код") {
                        Task { await env.startIndexing() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .font(.caption)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.1))
            
            Divider()
            
            // БАЛАНС И ТОКЕНЫ
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Баланс:").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let bal = env.chatVM.remainingBalance {
                        Text(String(format: "$%.4f", bal)).font(.system(.caption, design: .monospaced)).foregroundStyle(bal > 0 ? .green : .red)
                    }
                }
                HStack {
                    Image(systemName: "arrow.up.circle"); Text("\(env.chatVM.totalPromptTokens)")
                    Spacer()
                    Image(systemName: "arrow.down.circle"); Text("\(env.chatVM.totalCompletionTokens)")
                }.font(.system(.caption, design: .monospaced))
            }
            .padding(10)
            .background(Color.black.opacity(0.1))
        }
        .onAppear {
            Task { 
                await env.chatVM.loadTree(from: env.projectMap)
                await env.chatVM.refreshBalance()
                env.checkIfIndexed()
            }
        }
    }
}
