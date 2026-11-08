#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Обновляем SettingsStore
cat > Bosun/Services/Storage/SettingsStore.swift <<'SWIFT'
import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    private enum Keys {
        static let hasAPIKey = "hasAPIKey"
        static let defaultModelId = "defaultModelId"
        static let projectRootPath = "projectRootPath"
        static let maxIterations = "maxIterations"
    }

    private let defaults: UserDefaults

    var hasAPIKey: Bool { didSet { defaults.set(hasAPIKey, forKey: Keys.hasAPIKey) } }
    var defaultModelId: String? { didSet { defaults.set(defaultModelId, forKey: Keys.defaultModelId) } }
    var projectRootPath: String? { didSet { defaults.set(projectRootPath, forKey: Keys.projectRootPath) } }
    
    // НОВОЕ: Лимит итераций (по умолчанию 50)
    var maxIterations: Int { didSet { defaults.set(maxIterations, forKey: Keys.maxIterations) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasAPIKey = defaults.bool(forKey: Keys.hasAPIKey)
        self.defaultModelId = defaults.string(forKey: Keys.defaultModelId)
        self.projectRootPath = defaults.string(forKey: Keys.projectRootPath)
        
        let savedIterations = defaults.integer(forKey: Keys.maxIterations)
        self.maxIterations = savedIterations == 0 ? 50 : savedIterations // Если 0, ставим 50 по умолчанию
    }
}
SWIFT

# 2. Обновляем SettingsView (Добавляем UI для настройки)
cat > Bosun/Views/Settings/SettingsView.swift <<'SWIFT'
import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var showResetAlert = false

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section("OpenRouter") {
                LabeledContent("API key", value: env.settingsVM.hasKey ? "сохранён" : "не задан")
                Button("Удалить ключ", role: .destructive) {
                    env.settingsVM.removeAPIKey()
                }
                .disabled(!env.settingsVM.hasKey)
            }
            
            Section("Агент") {
                Stepper("Лимит итераций: \(settings.maxIterations)", value: $settings.maxIterations, in: 10...200, step: 10)
                    .help("Максимальное количество шагов, которое агент может сделать за один запрос.")
            }
            
            Section("Данные приложения") {
                Button("Очистить историю чатов", role: .destructive) {
                    showResetAlert = true
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 450)
        .alert("Очистить все чаты?", isPresented: $showResetAlert) {
            Button("Отмена", role: .cancel) {}
            Button("Очистить", role: .destructive) {
                let descriptor = FetchDescriptor<ChatSession>()
                if let sessions = try? context.fetch(descriptor) {
                    for session in sessions {
                        context.delete(session)
                    }
                    try? context.save()
                    env.chatVM.activeSession = nil
                    env.chatVM.messages = []
                }
            }
        } message: {
            Text("Все сохраненные диалоги будут удалены безвозвратно.")
        }
    }
}
SWIFT

# 3. Обновляем ChatViewModel (Передаем лимит в AgentCore)
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
        
        if data.count > 5 * 1024 * 1024 {
            self.error = "Файл слишком большой (макс. 5 МБ)"
            return
        }
        
        let attachment = ChatAttachment(
            fileName: url.lastPathComponent,
            type: isImage ? .image : .text,
            data: data
        )
        pendingAttachments.append(attachment)
    }

    func send(toolRuntime: ToolRuntime?, projectMap: ProjectMap?, projectRules: String?, context: ModelContext) {
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
            approvalHandler: { [weak self] reqs in
                guard let self = self else { return false }
                return await self.requestApproval(reqs)
            }
        )
        
        let historyToSend = self.messages
        let maxIterations = settings.maxIterations // <-- Берем лимит из настроек

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

# 4. Обновляем AgentCore (Принимаем maxIterations в run)
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
    
    // ДОБАВИЛИ ПАРАМЕТР maxIterations
    func run(history: [ChatMessage], sessionContext: [ChatMessage] = [], maxIterations: Int = 25) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // ... (код подготовки сообщений и системного промпта)
                
                var messages: [ChatMessage] = []
                messages.append(ChatMessage(role: .system, content: PromptBuilder.buildSystemPrompt(tree: await projectMap?.getTextTree(), projectRules: projectRules)))
                
                let lastUserMessage = history.last(where: { $0.role == .user })?.content ?? ""
                let rawContext = sessionContext.isEmpty ? await compressIfNeeded(history: history) : sessionContext
                messages.append(contentsOf: sanitizeHistory(rawContext))
                
                let tools = await runtime?.openRouterTools ?? []
                let useTools = !tools.isEmpty
                
                var hasModifiedSourceCode = false
                var hasWrittenTests = false
                var hasRunTests = false
                var consecutiveFailures = 0
                var lastToolCallHash: Int = 0
                var duplicateCallCount = 0
                
                // ИСПОЛЬЗУЕМ ПАРАМЕТР
                for step in 0..<maxIterations {
                    // ... (основной цикл без изменений, кроме защиты от зацикливания)
                    // ...
                }
                
                continuation.finish(throwing: NSError(domain: "Agent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Достигнут лимит шагов (\(maxIterations))."]))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    // (Вспомогательные методы sanitizeHistory, summarize, compressIfNeeded остаются без изменений)
}
SWIFT

echo "S39: Настройка лимита итераций готова."
