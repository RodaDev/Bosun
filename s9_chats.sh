#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

mkdir -p Bosun/Views/Sidebar

# 1. Модели данных (SwiftData)
cat > Bosun/Models/ChatSession.swift <<'SWIFT'
import Foundation
import SwiftData

@Model
final class ChatSession {
    var id: UUID
    var title: String
    var createdAt: Date
    var lastModified: Date
    
    @Relationship(deleteRule: .cascade, inverse: \StoredMessage.session)
    var messages: [StoredMessage]
    
    init(title: String = "Новый чат") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.lastModified = Date()
        self.messages = []
    }
}

@Model
final class StoredMessage {
    var id: UUID
    var role: String
    var content: String
    var toolCallsJson: String?
    var toolCallId: String?
    var timestamp: Date
    
    var session: ChatSession?
    
    init(from chatMessage: ChatMessage) {
        self.id = chatMessage.id
        self.role = chatMessage.role.rawValue
        self.content = chatMessage.content
        self.toolCallId = chatMessage.toolCallId
        self.timestamp = Date()
        
        if let calls = chatMessage.toolCalls, let data = try? JSONEncoder().encode(calls) {
            self.toolCallsJson = String(data: data, encoding: .utf8)
        }
    }
    
    func toChatMessage() -> ChatMessage {
        var calls: [ToolCall]? = nil
        if let json = toolCallsJson, let data = json.data(using: .utf8) {
            calls = try? JSONDecoder().decode([ToolCall].self, from: data)
        }
        return ChatMessage(
            id: id,
            role: ChatRole(rawValue: role) ?? .user,
            content: content,
            toolCalls: calls,
            toolCallId: toolCallId
        )
    }
}
SWIFT

# 2. BosunApp (Добавляем modelContainer)
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
            .modelContainer(for: [ChatSession.self, StoredMessage.self])
        }
        .windowStyle(.titleBar)
        .commands { CommandGroup(replacing: .newItem) {} }

        Settings {
            SettingsView().environment(env)
        }
    }
}
SWIFT

# 3. SessionListView (Список чатов)
cat > Bosun/Views/Sidebar/SessionListView.swift <<'SWIFT'
import SwiftUI
import SwiftData

struct SessionListView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var env
    
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
                            if env.chatVM.activeSession == session {
                                env.chatVM.activeSession = nil
                                env.chatVM.messages = []
                            }
                            context.delete(session)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let newSession = ChatSession()
                    context.insert(newSession)
                    env.chatVM.loadSession(newSession)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("Новый чат")
            }
        }
    }
}
SWIFT

# 4. Обновляем RootView (Добавляем левую панель)
cat > Bosun/App/RootView.swift <<'SWIFT'
import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationSplitView {
            SessionListView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            ProjectTreeView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if env.chatVM.activeSession != nil {
                ChatView(vm: env.chatVM)
            } else {
                VStack {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Выберите чат слева или создайте новый")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Bosun")
    }
}
SWIFT

# 5. Обновляем ChatViewModel (Интеграция с БД)
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
        
        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)
        
        // Сохраняем в БД
        let storedUser = StoredMessage(from: userMsg)
        storedUser.session = session
        context.insert(storedUser)
        
        if session.title == "Новый чат" {
            session.title = String(text.prefix(30)) + (text.count > 30 ? "..." : "")
        }
        session.lastModified = Date()
        
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
        
        let contextToSend = sessionContext
        sessionContext = []
        let history = contextToSend.isEmpty ? messages.dropLast() : messages.dropLast()

        currentTask = Task {
            var textBuffer = ""
            
            do {
                let stream = try await core.run(history: Array(history), sessionContext: contextToSend)
                
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

# 6. Composer (Передача context)
cat > Bosun/Views/Chat/Composer.swift <<'SWIFT'
import SwiftUI
import SwiftData

struct Composer: View {
    @Bindable var vm: ChatViewModel
    var env: AppEnvironment
    @Environment(\.modelContext) private var context
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    showPicker = true
                } label: {
                    Label(vm.selectedModelId ?? "Модель", systemImage: "cpu")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                Spacer()
                if vm.isRunning {
                    Button("Стоп", role: .destructive) { vm.cancel() }
                }
            }
            .font(.caption)

            HStack(alignment: .bottom) {
                TextField("Сообщение агенту…", text: $vm.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .onSubmit { vm.send(toolRuntime: env.toolRuntime, projectMap: env.projectMap, context: context) }
                
                if vm.isRunning && vm.streamingText.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 4)
                }
                
                Button {
                    vm.send(toolRuntime: env.toolRuntime, projectMap: env.projectMap, context: context)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!vm.canSend)
            }
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .sheet(isPresented: $showPicker) { ModelPickerSheet() }
    }
}
SWIFT

# 7. ChatView (Передача context в Composer)
cat > Bosun/Views/Chat/ChatView.swift <<'SWIFT'
import SwiftUI
import AppKit
import SwiftData

struct ChatView: View {
    @Bindable var vm: ChatViewModel
    @Environment(AppEnvironment.self) private var env
    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 0) {
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
                    if isRefreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                
                Button {
                    selectFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
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
SWIFT

echo "S9: История чатов (SwiftData) готова."
