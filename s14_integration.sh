#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Обновляем AppEnvironment (Добавляем ModelContext и SemanticSearchTool)
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
    
    var modelContext: ModelContext? // Передается из BosunApp
    
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
                
                Task { try? await idx.rebuild() }
            } else {
                sandbox = nil
                symbolIndex = nil
                projectMap = nil
                toolRuntime = nil
                gitService = nil
                indexerService = nil
                settings.projectRootPath = nil
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
}
SWIFT

# 2. Обновляем ProjectTreeView (Кнопка индексации)
cat > Bosun/Views/Project/ProjectTreeView.swift <<'SWIFT'
import SwiftUI
import SwiftData

struct ProjectTreeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var isIndexing = false
    @State private var indexProgress = ""

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
            
            if isIndexing {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(indexProgress).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.1))
            } else {
                Button {
                    isIndexing = true
                    Task {
                        // Привязываем контекст к AppEnvironment перед индексацией
                        env.modelContext = context
                        if env.projectRoot != nil {
                            env.projectRoot = env.projectRoot // перезагрузка инструментов
                        }
                        
                        if let indexer = env.indexerService {
                            try? await indexer.indexProject(context: context) { msg in
                                Task { @MainActor in self.indexProgress = msg }
                            }
                        }
                        isIndexing = false
                        indexProgress = ""
                    }
                } label: {
                    Label("Проиндексировать код", systemImage: "sparkles")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
            
            Divider()
            
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
            Task { await env.chatVM.loadTree(from: env.projectMap); await env.chatVM.refreshBalance() }
        }
    }
}
SWIFT

# 3. Обновляем ChatView (Прокидываем modelContext в AppEnvironment)
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
            if env.projectRoot != nil { env.projectRoot = env.projectRoot } // Перезагрузка тулзов
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

echo "S14: Интеграция RAG завершена."
