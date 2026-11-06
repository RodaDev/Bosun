#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

mkdir -p Bosun/Models

# 1. Создаем структуру IndexState
cat > Bosun/Models/IndexState.swift <<'SWIFT'
import Foundation

enum IndexStatus: Equatable {
    case notIndexed
    case indexing(progress: String)
    case indexed(date: Date)
    case error(String)
}

struct IndexState: Equatable {
    var status: IndexStatus = .notIndexed
    
    var isIndexing: Bool {
        if case .indexing = status { return true }
        return false
    }
    
    var isReady: Bool {
        if case .indexed = status { return true }
        return false
    }
    
    var progressMessage: String {
        if case .indexing(let msg) = status { return msg }
        return ""
    }
    
    var errorMessage: String? {
        if case .error(let msg) = status { return msg }
        return nil
    }
}
SWIFT

# 2. Обновляем AppEnvironment
cat > Bosun/App/AppEnvironment.swift <<'SWIFT'
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppEnvironment {
    let settings: SettingsStore
    let keychain: KeychainStore
    let openRouter: OpenRouterClient
    let chatVM: ChatViewModel
    let modelPickerVM: ModelPickerViewModel
    let settingsVM: SettingsViewModel

    var sandbox: Sandbox?
    var symbolIndex: SymbolIndex?
    var projectMap: ProjectMap?
    var toolRuntime: ToolRuntime?
    var gitService: GitService?
    var indexerService: IndexerService?
    
    var modelContext: ModelContext?
    var indexState = IndexState() // <-- Новое состояние индекса
    
    var projectRoot: URL? {
        didSet {
            if let root = projectRoot {
                let box = Sandbox(rootURL: root)
                let idx = SymbolIndex(rootURL: root)
                let map = ProjectMap(rootURL: root)
                let runner = XcodeBuildRunner(rootURL: root)
                let git = GitService(rootURL: root)
                
                self.sandbox = box
                self.symbolIndex = idx
                self.projectMap = map
                self.gitService = git
                self.indexerService = IndexerService(sandbox: box, client: openRouter)
                
                var tools: [AgentTool] = [
                    ListDirTool(sandbox: box),
                    ReadFileTool(sandbox: box),
                    SearchTool(sandbox: box),
                    FindSymbolTool(index: idx),
                    ListSymbolsTool(sandbox: box, index: idx),
                    WriteFileTool(sandbox: box),
                    EditFileTool(sandbox: box),
                    RunXcodebuildTool(runner: runner),
                    GitStatusTool(gitService: git),
                    GitDiffTool(gitService: git)
                ]
                
                if let ctx = modelContext {
                    tools.append(SemanticSearchTool(client: openRouter, context: ctx))
                }
                
                self.toolRuntime = ToolRuntime(registry: ToolRegistry(tools: tools))
                settings.projectRootPath = root.path
                self.indexState = IndexState() // Сбрасываем при смене проекта
                
                Task { try? await idx.rebuild() }
            } else {
                sandbox = nil; symbolIndex = nil; projectMap = nil; toolRuntime = nil
                gitService = nil; indexerService = nil; settings.projectRootPath = nil
                self.indexState = IndexState()
            }
        }
    }

    init() {
        let settings = SettingsStore()
        let keychain = KeychainStore()
        let transport = URLSessionTransport()
        let client = OpenRouterClient(transport: transport, keychain: keychain)

        self.settings = settings
        self.keychain = keychain
        self.openRouter = client
        self.chatVM = ChatViewModel(settings: settings, keychain: keychain, client: client)
        self.modelPickerVM = ModelPickerViewModel(client: client)
        self.settingsVM = SettingsViewModel(settings: settings, keychain: keychain)

        if self.keychain.loadAPIKey() == nil { self.settings.hasAPIKey = false }
        if let path = settings.projectRootPath { self.projectRoot = URL(fileURLWithPath: path) }
    }
    
    // Метод для запуска индексации
    func startIndexing() async {
        guard let indexer = indexerService, let context = modelContext else { return }
        
        indexState.status = .indexing(progress: "Подготовка...")
        
        do {
            try await indexer.indexProject(context: context) { msg in
                Task { @MainActor in
                    self.indexState.status = .indexing(progress: msg)
                }
            }
            self.indexState.status = .indexed(date: Date())
        } catch {
            self.indexState.status = .error(error.localizedDescription)
        }
    }
    
    func checkIfIndexed() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<CodeChunk>()
        if let count = try? context.fetchCount(descriptor), count > 0 {
            self.indexState.status = .indexed(date: Date())
        } else {
            self.indexState.status = .notIndexed
        }
    }
}
SWIFT

# 3. Обновляем ProjectTreeView (Красивый статус на основе IndexState)
cat > Bosun/Views/Project/ProjectTreeView.swift <<'SWIFT'
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
SWIFT

# 4. Обновляем ChatView (Авто-запуск индексации)
cat > Bosun/Views/Chat/ChatView.swift <<'SWIFT'
import SwiftUI
import AppKit
import SwiftData

struct ChatView: View {
    @Bindable var vm: ChatViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(env.projectRoot?.lastPathComponent ?? "Проект не выбран").font(.headline)
                Spacer()
                Button { Task { try? await env.gitService?.undoAllChanges(); _ = await env.projectMap?.refreshTree(); await vm.loadTree(from: env.projectMap) } } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).help("Откатить все изменения")
                Button { isRefreshing = true; Task { _ = await env.projectMap?.refreshTree(); await vm.loadTree(from: env.projectMap); isRefreshing = false } } label: { if isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") } }
                    .buttonStyle(.borderless)
                Button { selectFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.messages) { msg in
                            if !msg.content.isEmpty { MessageBubble(message: msg).id(msg.id) }
                            if let calls = msg.toolCalls {
                                ForEach(calls) { call in
                                    if let res = vm.completedToolCalls.first(where: { $0.toolCallId == call.id }) {
                                        ToolCallCard(call: call, result: res)
                                    } else { ToolCallCard(call: call, result: nil) }
                                }
                            }
                        }
                        if !vm.streamingText.isEmpty { MessageBubble(message: ChatMessage(role: .assistant, content: vm.streamingText)).id("stream") }
                        if let err = vm.error { Text(err).foregroundStyle(.red).font(.callout) }
                    }
                    .padding(16)
                }
                .onChange(of: vm.messages.count) { _, _ in if let last = vm.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
                .onChange(of: vm.streamingText) { _, _ in proxy.scrollTo("stream", anchor: .bottom) }
            }
            
            Divider()
            if env.projectRoot == nil { Text("Выберите проект, чтобы агент мог использовать инструменты.").font(.caption).foregroundStyle(.orange).padding(.top, 8) }
            Composer(vm: vm, env: env)
        }
        .onAppear {
            env.modelContext = context
            if env.projectRoot != nil { 
                env.projectRoot = env.projectRoot 
                // АВТО-ИНДЕКСАЦИЯ
                Task {
                    env.checkIfIndexed()
                    if !env.indexState.isReady && !env.indexState.isIndexing {
                        await env.startIndexing()
                    }
                }
            }
        }
        .sheet(isPresented: .init(get: { !vm.pendingApprovals.isEmpty }, set: { _ in })) {
            ApprovalSheet(requests: vm.pendingApprovals, onApprove: { allowSession in vm.resolveApproval(approved: true, allowSession: allowSession) }, onReject: { vm.resolveApproval(approved: false) })
        }
    }
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            env.projectRoot = url
            Task { await vm.loadTree(from: env.projectMap) }
        }
    }
}
SWIFT

echo "S15: IndexState и Авто-индексация готовы."
