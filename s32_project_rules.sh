#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Обновляем AppEnvironment (Чтение .bosunrules при выборе проекта)
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
    var projectRules: String? // <-- Новое свойство
    
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
                
                // ЧИТАЕМ ПРАВИЛА ПРОЕКТА
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
                self.projectRules = nil
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

# 2. Обновляем PromptBuilder (Внедряем правила)
cat > Bosun/Services/Agent/PromptBuilder.swift <<'SWIFT'
import Foundation

struct PromptBuilder {
    static func buildSystemPrompt(tree: String?, projectRules: String?) -> String {
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
        
        prompt += """
        ПРАВИЛА:
        1. Твоя единственная цель — выполнить задачу из ПОСЛЕДНЕГО сообщения пользователя.
        2. Сначала прочитай нужные файлы (максимум 3-4 файла), чтобы понять код.
        3. Как только ты понял проблему — СРАЗУ ИСПОЛЬЗУЙ `edit_file` для правок.
        4. НЕ ЧИТАЙ файлы повторно, если ты уже делал это в этой сессии.
        5. Отвечай кратко. Если закончил — напиши текстовый ответ и остановись.
        
        ИНСТРУМЕНТЫ ПОИСКА:
        - Если пользователь спрашивает "Где находится...", "Где обрабатывается...", "Как работает...", 
          ВСЕГДА используй `semantic_search`. 
        - Обычный `search` используй только тогда, когда тебе нужно найти конкретное имя переменной.
        
        КРИТИЧЕСКИЕ ПРАВИЛА ПРИ РЕДАКТИРОВАНИИ:
        1. Если ты удаляешь структуру, класс или функцию, ты ОБЯЗАН удалить его ЦЕЛИКОМ (от `struct` до последней `}`). 
           НИКОГДА не оставляй внутренности структуры висеть в воздухе, закомментировав только сигнатуру!
        2. ЧТОБЫ УДАЛИТЬ КОД: передай в `edit_file` параметр `new_string` как пустую строку `""`. 
           НЕ ПЫТАЙСЯ закомментировать код! Просто удали его.
        3. Если ты меняешь сигнатуру метода, ты ОБЯЗАН обновить все места, где этот метод вызывается.
        """
        
        return prompt
    }
}
SWIFT

# 3. Обновляем AgentCore (Передаем правила в PromptBuilder)
cat > Bosun/Services/Agent/AgentCore.swift <<'SWIFT'
import Foundation

actor AgentCore {
    private let client: OpenRouterClient
    private let runtime: ToolRuntime?
    private let model: String
    private let projectMap: ProjectMap?
    private let projectRules: String?
    private let approvalHandler: @Sendable ([ApprovalRequest]) async -> Bool
    
    private let contextLimit = 15000
    
    init(
        client: OpenRouterClient,
        runtime: ToolRuntime?,
        model: String,
        projectMap: ProjectMap?,
        projectRules: String?,
        approvalHandler: @Sendable @escaping ([ApprovalRequest]) async -> Bool
    ) {
        self.client = client
        self.runtime = runtime
        self.model = model
        self.projectMap = projectMap
        self.projectRules = projectRules
        self.approvalHandler = approvalHandler
    }
    
    func run(history: [ChatMessage], sessionContext: [ChatMessage] = []) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let tree = await projectMap?.getTextTree()
                let systemPrompt = PromptBuilder.buildSystemPrompt(tree: tree, projectRules: projectRules)
                
                var messages: [ChatMessage] = []
                messages.append(ChatMessage(role: .system, content: systemPrompt))
                
                let lastUserMessage = history.last(where: { $0.role == .user })?.content ?? ""
                let rawContext = sessionContext.isEmpty ? await compressIfNeeded(history: history) : sessionContext
                let safeContext = sanitizeHistory(rawContext)
                messages.append(contentsOf: safeContext)
                
                let tools = await runtime?.openRouterTools ?? []
                let useTools = !tools.isEmpty
                
                var consecutiveBuildFailures = 0
                var lastToolCallHash: Int = 0
                var duplicateCallCount = 0
                
                for step in 0..<25 {
                    var accumulatedText = ""
                    var accumulatedToolCalls: [ToolCall] = []
                    
                    var messagesToSend = messages
                    if step > 0 && !lastUserMessage.isEmpty {
                        let anchor = ChatMessage(
                            role: .system, 
                            content: "КРИТИЧЕСКИ ВАЖНО: Твоя задача — выполнить это: \"\(lastUserMessage)\". Переходи к действиям."
                        )
                        messagesToSend.append(anchor)
                    }
                    
                    do {
                        let stream = try await client.streamCompletion(
                            model: model, 
                            messages: messagesToSend, 
                            tools: useTools ? tools : nil
                        )
                        
                        for try await chunk in stream {
                            if !chunk.textDelta.isEmpty {
                                accumulatedText += chunk.textDelta
                                continuation.yield(.textDelta(chunk.textDelta))
                            }
                            if let tcs = chunk.toolCalls {
                                accumulatedToolCalls.append(contentsOf: tcs)
                            }
                            if let usage = chunk.usage {
                                continuation.yield(.usage(prompt: usage.promptTokens, completion: usage.completionTokens, cached: usage.cachedTokens))
                            }
                            if chunk.isDone { break }
                        }
                    } catch {
                        continuation.yield(.checkpoint(messages))
                        continuation.finish(throwing: error)
                        return
                    }
                    
                    if let firstCall = accumulatedToolCalls.first {
                        let callHash = (firstCall.function.name + firstCall.function.arguments).hashValue
                        if callHash == lastToolCallHash {
                            duplicateCallCount += 1
                            if duplicateCallCount >= 2 {
                                continuation.yield(.textDelta("\n\n*[Система: Обнаружено зацикливание. Остановка.]*"))
                                continuation.finish(throwing: NSError(domain: "Agent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Зацикливание на вызове инструмента."]))
                                return
                            }
                        } else {
                            lastToolCallHash = callHash
                            duplicateCallCount = 0
                        }
                    }
                    
                    if accumulatedToolCalls.isEmpty {
                        if !accumulatedText.isEmpty {
                            messages.append(ChatMessage(role: .assistant, content: accumulatedText))
                        }
                        if consecutiveBuildFailures > 0 && consecutiveBuildFailures <= 3 {
                            messages.append(ChatMessage(role: .system, content: "СБОРКА ВСЁ ЕЩЕ ПАДАЕТ. Исправь ошибки."))
                            continue
                        }
                        continuation.finish()
                        return
                    }
                    
                    let assistantMsg = ChatMessage(role: .assistant, content: accumulatedText, toolCalls: accumulatedToolCalls)
                    messages.append(assistantMsg)
                    
                    if let runtime = runtime {
                        let requests = await runtime.prepareApprovals(for: accumulatedToolCalls)
                        var approved = true
                        if !requests.isEmpty { approved = await approvalHandler(requests) }
                        
                        for call in accumulatedToolCalls {
                            continuation.yield(.toolCallStarted(call))
                            let result = approved ? await runtime.execute(call) : ToolResult.error(call.id, "Отклонено")
                            continuation.yield(.toolResult(result))
                            messages.append(ChatMessage(role: .tool, content: result.content, toolCallId: result.toolCallId))
                            
                            if call.function.name == "run_xcodebuild" || call.function.name == "run_build" {
                                if result.content.contains("error:") || result.content.contains("BUILD FAILED") || result.isError {
                                    consecutiveBuildFailures += 1
                                    messages.append(ChatMessage(role: .system, content: "СБОРКА УПАЛА. Проанализируй ошибки выше и исправь их."))
                                } else {
                                    consecutiveBuildFailures = 0
                                }
                            }
                        }
                    }
                    
                    continuation.yield(.checkpoint(messages))
                }
                continuation.finish(throwing: NSError(domain: "Agent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Достигнут лимит шагов."]))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    private func sanitizeHistory(_ history: [ChatMessage]) -> [ChatMessage] {
        var sanitized: [ChatMessage] = []
        var pendingToolCallIds: Set<String> = []
        
        for msg in history {
            if msg.role == .assistant, let calls = msg.toolCalls {
                sanitized.append(msg)
                for call in calls { pendingToolCallIds.insert(call.id) }
            } else if msg.role == .tool {
                if let callId = msg.toolCallId, pendingToolCallIds.contains(callId) {
                    sanitized.append(msg)
                    pendingToolCallIds.remove(callId)
                }
            } else {
                sanitized.append(msg)
            }
        }
        
        if !pendingToolCallIds.isEmpty {
            sanitized = sanitized.filter { msg in
                if msg.role == .assistant, let calls = msg.toolCalls {
                    let hasMissing = calls.contains { pendingToolCallIds.contains($0.id) }
                    return !hasMissing
                }
                return true
            }
        }
        return sanitized
    }
    
    private func summarize(messages: [ChatMessage], task: String) async -> String {
        var textToSummarize = ""
        for msg in messages {
            if msg.role == .user { textToSummarize += "Пользователь: \(msg.content)\n" }
            else if msg.role == .assistant, !msg.content.isEmpty { textToSummarize += "Ассистент: \(msg.content)\n" }
            else if msg.role == .tool { textToSummarize += "Результат инструмента: \(msg.content.prefix(100))...\n" }
        }
        let prompt = "Ты — система сжатия контекста. ГЛАВНАЯ ЗАДАЧА: \(task)\nНапиши краткое резюме (до 5 предложений)."
        do {
            let stream = try await client.streamCompletion(model: "openai/gpt-4o-mini", messages: [
                ChatMessage(role: .system, content: prompt),
                ChatMessage(role: .user, content: textToSummarize)
            ], tools: nil)
            var summary = ""
            for try await chunk in stream { summary += chunk.textDelta }
            return "КРАТКАЯ ИСТОРИЯ:\n\(summary)"
        } catch {
            return "КРАТКАЯ ИСТОРИЯ: Не удалось сжать. Выполняй задачу: \(task)"
        }
    }
    
    private func compressIfNeeded(history: [ChatMessage]) async -> [ChatMessage] {
        if history.count <= 15 { return history }
        let toSummarize = Array(history.prefix(history.count - 5))
        let recent = Array(history.suffix(5))
        var summaryText = "Краткая сводка предыдущих действий:\n"
        for msg in toSummarize {
            if msg.role == .user { summaryText += "- Пользователь: \(msg.content.prefix(100))\n" }
            else if msg.role == .assistant, !msg.content.isEmpty { summaryText += "- Ассистент: \(msg.content.prefix(100))\n" }
            else if msg.role == .tool { summaryText += "- Инструмент выполнен.\n" }
        }
        return [ChatMessage(role: .system, content: summaryText)] + recent
    }
}
SWIFT

# 4. Обновляем ChatViewModel (Передаем projectRules в AgentCore)
cat > Bosun/ViewModels/ChatViewModel.swift <<'SWIFT'
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ChatViewModel {
    var draft: String = ""
    var messages: [ChatMessage] = []
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
        !isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedModelId != nil && activeSession != nil
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
    }

    func send(toolRuntime: ToolRuntime?, projectMap: ProjectMap?, projectRules: String?, context: ModelContext) {
        guard canSend, let model = selectedModelId, let session = activeSession else { return }
        
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        error = nil
        streamingText = ""
        activeToolCalls = []
        completedToolCalls = []
        pendingApprovals = []
        sessionContext = []
        
        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)
        
        let storedUser = StoredMessage(from: userMsg)
        storedUser.session = session
        context.insert(storedUser)
        
        if session.title == "Новый диалог" {
            session.title = String(text.prefix(30)) + (text.count > 30 ? "..." : "")
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
            approvalHandler: { [weak self] reqs in
                guard let self = self else { return false }
                return await self.requestApproval(reqs)
            }
        )
        
        let historyToSend = self.messages

        currentTask = Task {
            var textBuffer = ""
            
            do {
                let stream = try await core.run(history: historyToSend, sessionContext: [])
                
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

# 5. Обновляем Composer (Передаем projectRules)
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
                                Button {
                                    vm.pendingAttachments.removeAll { $0.id == att.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            HStack(spacing: 8) {
                Button { selectFile() } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless)
                Button { showPicker = true } label: { Label(vm.selectedModelId ?? "Модель", systemImage: "cpu").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderless)
                Spacer()
                if vm.isRunning { Button("Стоп", role: .destructive) { vm.cancel() } }
            }
            .font(.caption)

            HStack(alignment: .bottom) {
                TextField("Сообщение агенту…", text: $vm.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .onSubmit { 
                        Task { vm.send(toolRuntime: env.toolRuntime, projectMap: env.projectMap, projectRules: env.projectRules, context: context) } 
                    }
                
                if vm.isRunning && vm.streamingText.isEmpty {
                    ProgressView().controlSize(.small).padding(.bottom, 4)
                }
                
                Button {
                    Task { vm.send(toolRuntime: env.toolRuntime, projectMap: env.projectMap, projectRules: env.projectRules, context: context) }
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
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls { vm.addFile(url: url) }
        }
    }
}
SWIFT

echo "S32: Правила проекта (.bosunrules) готовы."
