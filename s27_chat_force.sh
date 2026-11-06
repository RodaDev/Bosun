#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Обновляем SessionListView (Принудительное обновление)
cat > Bosun/Views/Sidebar/SessionListView.swift <<'SWIFT'
import SwiftUI
import SwiftData

struct SessionListView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var env
    
    // Query автоматически обновит список, когда мы вызовем context.save()
    @Query(sort: \ChatSession.lastModified, order: .reverse) private var sessions: [ChatSession]
    
    var body: some View {
        List(selection: Binding(
            get: { env.chatVM.activeSession?.id },
            set: { newId in
                if let id = newId, let session = sessions.first(where: { $0.id == id }) {
                    env.chatVM.loadSession(session)
                }
            }
        )) {
            Section("История чатов") {
                ForEach(sessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(session.lastModified, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(session.id)
                    .contextMenu {
                        Button("Удалить", role: .destructive) {
                            if env.chatVM.activeSession?.id == session.id {
                                env.chatVM.activeSession = nil
                                env.chatVM.messages = []
                            }
                            context.delete(session)
                            try? context.save()
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createNewSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("Новый чат")
            }
        }
    }
    
    private func createNewSession() {
        let newSession = ChatSession()
        context.insert(newSession)
        try? context.save() // Обязательно сохраняем
        env.chatVM.loadSession(newSession)
    }
}
SWIFT

# 2. Добавляем очистку базы в SettingsView (на случай если база залочилась)
cat > Bosun/Views/Settings/SettingsView.swift <<'SWIFT'
import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var showResetAlert = false

    var body: some View {
        Form {
            Section("OpenRouter") {
                LabeledContent("API key", value: env.settingsVM.hasKey ? "сохранён" : "не задан")
                Button("Удалить ключ", role: .destructive) {
                    env.settingsVM.removeAPIKey()
                }
                .disabled(!env.settingsVM.hasKey)
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

# 3. Убеждаемся, что ChatViewModel сохраняет сессию при создании
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

    func send(toolRuntime: ToolRuntime?, projectMap: ProjectMap?, context: ModelContext) {
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
        
        if session.title == "Новый чат" {
            session.title = String(text.prefix(30)) + (text.count > 30 ? "..." : "")
        }
        session.lastModified = Date()
        try? context.save() // Сохраняем сообщение пользователя
        
        isRunning = true

        let core = AgentCore(
            client: client,
            runtime: toolRuntime,
            model: model,
            projectMap: projectMap,
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

echo "S27: Принудительный фикс чатов и очистка базы готовы."
