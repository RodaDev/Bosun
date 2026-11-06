#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Обновляем модель CodeChunk
cat > Bosun/Models/CodeChunk.swift <<'SWIFT'
import Foundation
import SwiftData

@Model
final class CodeChunk {
    @Attribute(.unique) var id: UUID
    var filePath: String
    var content: String
    var fileModifiedDate: Date
    var vector: [Float]
    
    init(filePath: String, content: String, fileModifiedDate: Date, vector: [Float]) {
        self.id = UUID()
        self.filePath = filePath
        self.content = content
        self.fileModifiedDate = fileModifiedDate
        self.vector = vector
    }
}
SWIFT

# 2. Обновляем GitService (Добавляем методы для индексации)
cat > Bosun/Services/Git/GitService.swift <<'SWIFT'
import Foundation

actor GitService {
    private let rootURL: URL
    
    init(rootURL: URL) {
        self.rootURL = rootURL
    }
    
    private func runGit(_ arguments: [String]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = rootURL
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
    
    func undoAllChanges() async throws {
        _ = await runGit(["checkout", "."])
        _ = await runGit(["clean", "-fd"])
    }
    
    func getStatus() async -> String {
        let status = await runGit(["status", "--short"])
        return status.isEmpty ? "Нет изменений" : status
    }
    
    func getDiff() async -> String {
        return await runGit(["diff"])
    }
    
    /// Возвращает список измененных или новых файлов (без коммита)
    func getChangedFiles() async -> [String] {
        let output = await runGit(["status", "--porcelain"])
        return output.components(separatedBy: .newlines)
            .compactMap { line -> String? in
                guard line.count > 3 else { return nil }
                // Формат: " M path" или "?? path". Берем всё после первых 3 символов
                return String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
    }
}

// Инструменты
struct GitStatusTool: AgentTool {
    let gitService: GitService
    var definition: ToolDefinition {
        ToolDefinition(name: "git_status", description: "Показывает измененные файлы", parameters: [:])
    }
    func execute(arguments: String) async throws -> String {
        return await gitService.getStatus()
    }
}

struct GitDiffTool: AgentTool {
    let gitService: GitService
    var definition: ToolDefinition {
        ToolDefinition(name: "git_diff", description: "Показывает построчный diff изменений", parameters: [:])
    }
    func execute(arguments: String) async throws -> String {
        let diff = await gitService.getDiff()
        return diff.isEmpty ? "Нет изменений" : String(diff.prefix(5000))
    }
}
SWIFT

# 3. Переписываем IndexerService (Гибридный алгоритм)
cat > Bosun/Services/RAG/IndexerService.swift <<'SWIFT'
import Foundation
import SwiftData

actor IndexerService {
    private let sandbox: Sandbox
    private let client: OpenRouterClient
    private let gitService: GitService
    
    init(sandbox: Sandbox, client: OpenRouterClient, gitService: GitService) {
        self.sandbox = sandbox
        self.client = client
        self.gitService = gitService
    }
    
    private func chunkText(_ text: String, chunkSize: Int = 1500, overlap: Int = 200) -> [String] {
        var chunks: [String] = []
        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            let endIndex = text.index(currentIndex, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[currentIndex..<endIndex]))
            if endIndex == text.endIndex { break }
            currentIndex = text.index(endIndex, offsetBy: -overlap)
        }
        return chunks
    }
    
    func indexProject(context: ModelContext, progress: @escaping @Sendable (String) -> Void) async throws {
        let root = await sandbox.rootURL
        
        // 1. Получаем список измененных файлов (через Git, либо через сканирование)
        var filesToIndex: [URL] = []
        
        let gitChanged = await gitService.getChangedFiles()
        if !gitChanged.isEmpty {
            progress("Git: найдено \(gitChanged.count) измененных файлов...")
            for path in gitChanged {
                let url = root.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path) && (url.pathExtension == "swift" || url.pathExtension == "md") {
                    filesToIndex.append(url)
                }
            }
        } else {
            // Фолбэк по mtime, если Git пуст или нет репозитория
            let existingChunks = try context.fetch(FetchDescriptor<CodeChunk>())
            var indexedFiles: [String: Date] = [:]
            for chunk in existingChunks {
                indexedFiles[chunk.filePath] = chunk.fileModifiedDate
            }
            
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            for case let url as URL in enumerator {
                if ExcludedPaths.names.contains(where: { url.path.contains("/\($0)/") }) { continue }
                guard url.pathExtension == "swift" || url.pathExtension == "md" else { continue }
                
                let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                
                // Если файла нет в базе ИЛИ он изменен после последней индексации
                if let existingDate = indexedFiles[path] {
                    if modDate > existingDate {
                        filesToIndex.append(url)
                    }
                } else {
                    filesToIndex.append(url)
                }
            }
        }
        
        if filesToIndex.isEmpty {
            progress("Все файлы актуальны. Индексация не требуется.")
            return
        }
        
        // 2. Удаляем старые чанки для этих файлов
        let pathsToIndex = filesToIndex.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
        let existingChunks = try context.fetch(FetchDescriptor<CodeChunk>())
        for chunk in existingChunks {
            if pathsToIndex.contains(chunk.filePath) {
                context.delete(chunk)
            }
        }
        try context.save()
        
        progress("Индексация \(filesToIndex.count) файлов...")
        
        // 3. Индексируем
        for (index, fileURL) in filesToIndex.enumerated() {
            let path = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let textChunks = chunkText(content)
            
            progress("Индексация \(index + 1)/\(filesToIndex.count): \(path)")
            
            for chunk in textChunks {
                if let vector = try? await client.fetchEmbedding(text: chunk) {
                    let codeChunk = CodeChunk(filePath: path, content: chunk, fileModifiedDate: modDate, vector: vector)
                    context.insert(codeChunk)
                }
            }
            try context.save()
        }
        progress("Индексация завершена.")
    }
}
SWIFT

# 4. Обновляем AppEnvironment (Авто-запуск и передача GitService в Indexer)
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
    var indexState = IndexState()
    
    var projectRoot: URL? {
        didSet {
            if let root = projectRoot {
                let box = Sandbox(rootURL: root)
                let idx = SymbolIndex(rootURL: root)
                let map = ProjectMap(rootURL: root)
                let runner = XcodeBuildRunner(rootURL: root)
                let git = GitService(rootURL: root)
                
                self.sandbox = box; self.symbolIndex = idx; self.projectMap = map; self.gitService = git
                self.indexerService = IndexerService(sandbox: box, client: openRouter, gitService: git)
                
                var tools: [AgentTool] = [
                    ListDirTool(sandbox: box), ReadFileTool(sandbox: box), SearchTool(sandbox: box),
                    FindSymbolTool(index: idx), ListSymbolsTool(sandbox: box, index: idx),
                    WriteFileTool(sandbox: box), EditFileTool(sandbox: box),
                    RunXcodebuildTool(runner: runner), GitStatusTool(gitService: git), GitDiffTool(gitService: git)
                ]
                if let ctx = modelContext {
                    tools.append(SemanticSearchTool(client: openRouter, context: ctx))
                }
                self.toolRuntime = ToolRuntime(registry: ToolRegistry(tools: tools))
                settings.projectRootPath = root.path
                self.indexState = IndexState()
                
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

        self.settings = settings; self.keychain = keychain; self.openRouter = client
        self.chatVM = ChatViewModel(settings: settings, keychain: keychain, client: client)
        self.modelPickerVM = ModelPickerViewModel(client: client)
        self.settingsVM = SettingsViewModel(settings: settings, keychain: keychain)

        if self.keychain.loadAPIKey() == nil { self.settings.hasAPIKey = false }
        if let path = settings.projectRootPath { self.projectRoot = URL(fileURLWithPath: path) }
    }
    
    func startIndexing(context: ModelContext) async {
        self.modelContext = context
        guard let indexer = indexerService else { return }
        indexState.status = .indexing(progress: "Подготовка...")
        do {
            try await indexer.indexProject(context: context) { msg in
                Task { @MainActor in self.indexState.status = .indexing(progress: msg) }
            }
            self.indexState.status = .indexed(date: Date())
        } catch {
            self.indexState.status = .error(error.localizedDescription)
        }
    }
    
    func checkIfIndexed(context: ModelContext) {
        let descriptor = FetchDescriptor<CodeChunk>()
        if let count = try? context.fetchCount(descriptor), count > 0 {
            self.indexState.status = .indexed(date: Date())
        } else {
            self.indexState.status = .notIndexed
        }
    }
}
SWIFT

# 5. Обновляем ChatView (Фоновая автоиндексация при старте)
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
                // АВТО-ИНДЕКСАЦИЯ (Только если не идет процесс)
                Task {
                    env.checkIfIndexed(context: context)
                    if !env.indexState.isReady && !env.indexState.isIndexing {
                        await env.startIndexing(context: context)
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

echo "S17: Гибридная индексация (Git + mtime) готова."
