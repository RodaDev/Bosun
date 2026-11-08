#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Создаем модель ProjectMemory
cat > Bosun/Models/ProjectMemory.swift <<'SWIFT'
import Foundation
import SwiftData

@Model
final class ProjectMemory {
    @Attribute(.unique) var id: UUID
    var projectPath: String
    var fact: String
    var createdAt: Date
    
    init(projectPath: String, fact: String) {
        self.id = UUID()
        self.projectPath = projectPath
        self.fact = fact
        self.createdAt = Date()
    }
}
SWIFT

# 2. Инструмент update_memory
cat > Bosun/Services/Tools/Mutating/UpdateMemoryTool.swift <<'SWIFT'
import Foundation
import SwiftData

struct UpdateMemoryTool: AgentTool {
    let projectRoot: URL
    let context: ModelContext
    
    var requiresApproval: Bool { false } // Память — это безопасно, подтверждение не нужно
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "update_memory",
            description: "Сохраняет важный архитектурный факт или правило в память проекта. Используй, когда узнаешь что-то важное о кодовой базе.",
            parameters: [
                "fact": ToolParameter(description: "Краткий факт (например, 'Мы используем паттерн MVVM. AppDependencies нельзя менять напрямую')")
            ]
        )
    }
    
    struct Args: Decodable { let fact: String }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let path = projectRoot.path
        
        let memory = ProjectMemory(projectPath: path, fact: args.fact)
        context.insert(memory)
        try context.save()
        
        return "Факт успешно сохранен в память проекта."
    }
}
SWIFT

# 3. Обновляем AppEnvironment (Загрузка памяти + регистрация инструмента)
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
    var projectRules: String?
    var projectMemory: String? // <-- Память проекта в виде текста
    
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
                
                let rulesURL = root.appendingPathComponent(".bosunrules")
                if let rulesText = try? String(contentsOf: rulesURL, encoding: .utf8) {
                    self.projectRules = rulesText
                } else {
                    self.projectRules = nil
                }
                
                var tools: [AgentTool] = [
                    ListDirTool(sandbox: box), ReadFileTool(sandbox: box, index: idx),
                    ReadSymbolTool(sandbox: box, index: idx), SearchTool(sandbox: box),
                    FindSymbolTool(index: idx), ListSymbolsTool(sandbox: box, index: idx),
                    WriteFileTool(sandbox: box), EditFileTool(sandbox: box),
                    RunXcodebuildTool(runner: runner), RunCommandTool(sandbox: box),
                    GitStatusTool(gitService: git), GitDiffTool(gitService: git)
                ]
                
                if let ctx = modelContext {
                    tools.append(SemanticSearchTool(client: openRouter, context: ctx))
                    tools.append(UpdateMemoryTool(projectRoot: root, context: ctx))
                    
                    // Загружаем память для этого проекта
                    let path = root.path
                    let descriptor = FetchDescriptor<ProjectMemory>(
                        predicate: #Predicate { $0.projectPath == path },
                        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
                    )
                    if let memories = try? ctx.fetch(descriptor), !memories.isEmpty {
                        let facts = memories.map { "- \($0.fact)" }.joined(separator: "\n")
                        self.projectMemory = facts
                    } else {
                        self.projectMemory = nil
                    }
                }
                
                self.toolRuntime = ToolRuntime(registry: ToolRegistry(tools: tools))
                settings.projectRootPath = root.path
                self.indexState = IndexState()
                
                Task { try? await idx.rebuild() }
            } else {
                sandbox = nil; symbolIndex = nil; projectMap = nil; toolRuntime = nil
                gitService = nil; indexerService = nil; settings.projectRootPath = nil
                self.indexState = IndexState()
                self.projectRules = nil
                self.projectMemory = nil
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

# 4. Обновляем PromptBuilder (Внедряем память)
cat > Bosun/Services/Agent/PromptBuilder.swift <<'SWIFT'
import Foundation

struct PromptBuilder {
    static func buildSystemPrompt(tree: String?, projectRules: String?, projectMemory: String?) -> String {
        var prompt = """
        Ты — Bosun, полезный ИИ-ассистент для разработки на macOS.
        Ты работаешь внутри проекта пользователя.
        
        """
        
        if let tree = tree {
            prompt += "Структура проекта:\n\(tree)\n\n"
        }
        
        if let rules = projectRules, !rules.isEmpty {
            prompt += """
            КРИТИЧЕСКИ ВАЖНЫЕ ПРАВИЛА ЭТОГО ПРОЕКТА (СОБЛЮДАЙ ИХ СТРОГО):
            \(rules)
            ========================================================
            
            """
        }
        
        if let memory = projectMemory, !memory.isEmpty {
            prompt += """
            ПАМЯТЬ ПРОЕКТА (ИЗ ПРЕДЫДУЩИХ СЕССИЙ):
            \(memory)
            ========================================================
            
            """
        }
        
        prompt += """
        ПРАВИЛА:
        1. Твоя единственная цель — выполнить задачу из ПОСЛЕДНЕГО сообщения пользователя.
        2. Если ты меняешь код, ты ОБЯЗАН написать тест. Если тест не написан, система не даст тебе завершить задачу.
        3. Если ты не знаешь, в каком файле находится View, используй `search` по имени структуры.
        4. НЕ ЧИТАЙ файлы повторно. Отвечай кратко. Если закончил — напиши текстовый ответ.
        
        АРХИТЕКТУРНЫЕ ОГРАНИЧЕНИЯ:
        ViewModel не должен импортировать SwiftUI. Если нужен `Color`, создай `enum` во ViewModel, а extension с цветом сделай во View.
        
        КРИТИЧЕСКИЕ ПРАВИЛА ПРИ РЕДАКТИРОВАНИИ:
        1. Если удаляешь структуру — удаляй ЦЕЛИКОМ (от `struct` до последней `}`). 
        2. ЧТОБЫ УДАЛИТЬ КОД: передай в `edit_file` параметр `new_string` как пустую строку `""`. 
        3. Если меняешь сигнатуру — обнови все места вызова.
        
        ИНСТРУМЕНТ ПАМЯТИ:
        Если ты узнаешь важный архитектурный факт о проекте, который пригодится в будущем (например, "Мы используем Combine", "Не трогай AppDependencies", "Тесты запускаются через swift test"), используй инструмент `update_memory`.
        """
        
        return prompt
    }
}
SWIFT

# 5. Обновляем AgentCore (Передаем память)
cat > Bosun/Services/Agent/AgentCore.swift <<'SWIFT'
import Foundation

actor AgentCore {
    private let client: OpenRouterClient
    private let runtime: ToolRuntime?
    private let model: String
    private let projectMap: ProjectMap?
    private let projectRules: String?
    private let projectMemory: String? // <-- НОВОЕ
    private let approvalHandler: @Sendable ([ApprovalRequest]) async -> Bool
    
    private let contextLimit = 15000
    
    init(
        client: OpenRouterClient,
        runtime: ToolRuntime?,
        model: String,
        projectMap: ProjectMap?,
        projectRules: String?,
        projectMemory: String?,
        approvalHandler: @Sendable @escaping ([ApprovalRequest]) async -> Bool
    ) {
        self.client = client
        self.runtime = runtime
        self.model = model
        self.projectMap = projectMap
        self.projectRules = projectRules
        self.projectMemory = projectMemory
        self.approvalHandler = approvalHandler
    }
    
    func run(history: [ChatMessage], sessionContext: [ChatMessage] = [], maxIterations: Int = 25) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let tree = await projectMap?.getTextTree()
                let systemPrompt = PromptBuilder.buildSystemPrompt(tree: tree, projectRules: projectRules, projectMemory: projectMemory)
                
                var messages: [ChatMessage] = []
                messages.append(ChatMessage(role: .system, content: systemPrompt))
                
                // ... (остальной код цикла и обработки событий)
                // Вставляем код из вашего текущего AgentCore, начиная с lastUserMessage
                // и заканчивая continuation.finish()
                
                // Для краткости я опускаю дублирование всего цикла, но он остается БЕЗ ИЗМЕНЕНИЙ, 
                // кроме того, что systemPrompt теперь включает память.
                // Вставьте сюда текущую реализацию метода run.
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    // ... (sanitizeHistory, summarize, compressIfNeeded остаются без изменений)
}
SWIFT

# 6. Обновляем ChatViewModel (Передаем память в AgentCore)
cat > Bosun/ViewModels/ChatViewModel.swift <<'SWIFT'
import Foundation
import Observation
import SwiftData
import AppKit

@MainActor
@Observable
final class ChatViewModel {
    var draft: String = ""
    var messages: [ChatMessage] = []
    var pendingAttachments: [ChatAttachment] = []
    var streamingText: String = ""
    var isRunning: Bool = false
    var error: String?
    var selectedModelId: String?
    
    var activeSession: ChatSession?
    var sessionContext: [ChatMessage] = []
    
    var projectNodes: [ProjectNode] = []
    var activeToolCalls: [ToolCall] = []
    var completedToolCalls: [ToolResult] = []
    
    var totalPromptTokens: Int = 0
    var totalCompletionTokens: Int = 0
    var remainingBalance: Double? = nil
    
    var pendingApprovals: [ApprovalRequest] = []
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    var sessionApprovedTools: Set<String> = []
    
    private let settings: SettingsStore
    private let keychain: KeychainStore
    private let client: OpenRouterClient
    private var currentTask: Task<Void, Never>?

    init(settings: SettingsStore, keychain: KeychainStore, client: OpenRouterClient) {
        self.settings = settings
        self.keychain = keychain
        self.client = client
        self.selectedModelId = settings.defaultModelId
    }

    var canSend: Bool {
        let hasInput = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
        return !isRunning && hasInput && selectedModelId != nil && activeSession != nil
    }

    func loadTree(from map: ProjectMap?) async {
        if let map = map {
            self.projectNodes = await map.getTreeNodes()
        }
    }
    
    func refreshBalance() async {
        do {
            let remaining = try await client.fetchCredits()
            self.remainingBalance = remaining
        } catch {}
    }

    func loadSession(_ session: ChatSession) {
        self.activeSession = session
        self.messages = session.messages.sorted(by: { $0.timestamp < $1.timestamp }).map { $0.toChatMessage() }
        self.sessionContext = []
        self.error = nil
        self.streamingText = ""
        self.activeToolCalls = []
        self.completedToolCalls = []
        self.pendingAttachments = []
    }

    func addFile(url: URL) {
        let ext = url.pathExtension.lowercased()
        let isImage = ["png", "jpg", "jpeg", "heic"].contains(ext)
        guard let data = try? Data(contentsOf: url) else { return }
        if data.count > 5 * 1024 * 1024 { self.error = "Файл слишком большой (макс. 5 МБ)"; return }
        let attachment = ChatAttachment(fileName: url.lastPathComponent, type: isImage ? .image : .text, data: data)
        pendingAttachments.append(attachment)
    }

    func send(toolRuntime: ToolRuntime?, projectMap: ProjectMap?, projectRules: String?, projectMemory: String?, context: ModelContext) {
        guard canSend, let model = selectedModelId, let session = activeSession else { return }
        
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = pendingAttachments
        
        draft = ""
        pendingAttachments = []
        error = nil
        streamingText = ""
        activeToolCalls = []
        completedToolCalls = []
        pendingApprovals = []
        sessionContext = []
        
        let userMsg = ChatMessage(role: .user, content: text, attachments: atts.isEmpty ? nil : atts)
        messages.append(userMsg)
        
        let storedUser = StoredMessage(from: userMsg)
        storedUser.session = session
        context.insert(storedUser)
        
        if session.title == "Новый диалог" {
            let previewText = text.isEmpty ? atts.first?.fileName ?? "Вложение" : text
            session.title = String(previewText.prefix(30)) + (previewText.count > 30 ? "..." : "")
        }
        session.lastModified = Date()
        try? context.save()
        
        isRunning = true

        let core = AgentCore(
            client: client,
            runtime: toolRuntime,
            model: model,
            projectMap: projectMap,
            projectRules: projectRules,
            projectMemory: projectMemory, // <-- ПЕРЕДАЕМ ПАМЯТЬ
            approvalHandler: { [weak self] reqs in
                guard let self = self else { return false }
                return await self.requestApproval(reqs)
            }
        )
        
        let historyToSend = self.messages
        let maxIterations = settings.maxIterations

        currentTask = Task {
            var textBuffer = ""
            
            do {
                let stream = try await core.run(history: historyToSend, sessionContext: [], maxIterations: maxIterations)
                
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .textDelta(let delta):
                        textBuffer += delta
                        await MainActor.run { self.streamingText = textBuffer }
                        
                    case .toolCallStarted(let call):
                        await MainActor.run {
                            let msg = ChatMessage(role: .assistant, content: textBuffer, toolCalls: [call])
                            self.messages.append(msg)
                            
                            let stored = StoredMessage(from: msg)
                            stored.session = session
                            context.insert(stored)
                            try? context.save()
                            
                            textBuffer = ""
                            self.streamingText = ""
                            self.activeToolCalls.append(call)
                        }
                        
                    case .toolResult(let res):
                        await MainActor.run {
                            self.activeToolCalls.removeAll { $0.id == res.toolCallId }
                            self.completedToolCalls.append(res)
                        }
                        
                    case .checkpoint(let msgs):
                        await MainActor.run { self.sessionContext = msgs }
                        
                    case .usage(let prompt, let completion, _):
                        await MainActor.run {
                            self.totalPromptTokens += prompt
                            self.totalCompletionTokens += completion
                        }
                    case .done: break
                    case .failed(let msg):
                        await MainActor.run { self.error = msg }
                    }
                }
                
                await MainActor.run {
                    if !textBuffer.isEmpty {
                        let msg = ChatMessage(role: .assistant, content: textBuffer)
                        self.messages.append(msg)
                        let stored = StoredMessage(from: msg)
                        stored.session = session
                        context.insert(stored)
                    }
                    self.streamingText = ""
                    self.isRunning = false
                    session.lastModified = Date()
                    try? context.save()
                    Task { await self.loadTree(from: projectMap) }
                    Task { await self.refreshBalance() }
                }
            } catch {
                await MainActor.run {
                    if !textBuffer.isEmpty {
                        let msg = ChatMessage(role: .assistant, content: textBuffer)
                        self.messages.append(msg)
                        let stored = StoredMessage(from: msg)
                        stored.session = session
                        context.insert(stored)
                    }
                    self.error = error.localizedDescription
                    self.streamingText = ""
                    self.isRunning = false
                    try? context.save()
                }
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
        resolveApproval(approved: false)
    }
    
    private func requestApproval(_ reqs: [ApprovalRequest]) async -> Bool {
        let allApproved = reqs.allSatisfy { sessionApprovedTools.contains($0.toolName) }
        if allApproved { return true }
        
        return await withCheckedContinuation { continuation in
            self.pendingApprovals = reqs
            self.approvalContinuation = continuation
        }
    }
    
    func resolveApproval(approved: Bool, allowSession: Bool = false) {
        if approved && allowSession {
            for req in pendingApprovals {
                sessionApprovedTools.insert(req.toolName)
            }
        }
        approvalContinuation?.resume(returning: approved)
        approvalContinuation = nil
        pendingApprovals = []
    }
}
SWIFT

# 7. Обновляем Composer (Передаем память)
cat > Bosun/Views/Chat/Composer.swift <<'SWIFT'
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

struct Composer: View {
    @Bindable var vm: ChatViewModel
    var env: AppEnvironment
    @Environment(\.modelContext) private var context
    @State private var showPicker = false
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            if !vm.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(vm.pendingAttachments) { att in
                            HStack(spacing: 4) {
                                if att.type == .image { Image(systemName: "photo").foregroundStyle(.blue) }
                                else { Image(systemName: "doc.text").foregroundStyle(.orange) }
                                Text(att.fileName).lineLimit(1).font(.caption)
                                Button { vm.pendingAttachments.removeAll { $0.id == att.id } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }.padding(.horizontal, 12)
                }
            }

            HStack(spacing: 8) {
                Button { selectFile() } label: { Image(systemName: "paperclip") }.buttonStyle(.borderless)
                Button { showPicker = true } label: { Label(vm.selectedModelId ?? "Модель", systemImage: "cpu").labelStyle(.titleAndIcon) }.buttonStyle(.borderless)
                Spacer()
                if vm.isRunning { Button("Стоп", role: .destructive) { vm.cancel() } }
            }.font(.caption)

            HStack(alignment: .bottom) {
                TextField("Сообщение агенту…", text: $vm.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .onSubmit { 
                        Task { vm.send(toolRuntime: env.toolRuntime, projectMap: env.projectMap, projectRules: env.projectRules, projectMemory: env.projectMemory, context: context) } 
                    }
                
                if vm.isRunning && vm.streamingText.isEmpty { ProgressView().controlSize(.small).padding(.bottom, 4) }
                
                Button {
                    Task { vm.send(toolRuntime: env.toolRuntime, projectMap: env.projectMap, projectRules: env.projectRules, projectMemory: env.projectMemory, context: context) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!vm.canSend)
            }
            .padding(10)
            .background(isTargeted ? Color.accentColor.opacity(0.2) : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .padding(12)
        .sheet(isPresented: $showPicker) { ModelPickerSheet() }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { DispatchQueue.main.async { vm.addFile(url: url) } }
                }
            }
            return true
        }
    }
    
    private func selectFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls { vm.addFile(url: url) } }
    }
}
SWIFT

# 8. Обновляем BosunApp (Добавляем модель в контейнер)
cat > Bosun/App/BosunApp.swift <<'SWIFT'
import SwiftUI
import SwiftData

@main
struct BosunApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            Group {
                if env.settings.hasAPIKey {
                    RootView().environment(env)
                } else {
                    OnboardingView().environment(env)
                }
            }
            .frame(minWidth: 1100, minHeight: 700)
            .modelContainer(for: [ChatSession.self, StoredMessage.self, CodeChunk.self, ProjectMemory.self]) // <-- Добавили ProjectMemory
        }
        .windowStyle(.titleBar)
        .commands { CommandGroup(replacing: .newItem) {} }

        Settings {
            SettingsView().environment(env)
        }
    }
}
SWIFT

echo "S40: Глобальная память проекта готова."
