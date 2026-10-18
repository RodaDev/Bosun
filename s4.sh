#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

mkdir -p Bosun/Services/Index
mkdir -p BosunTests

# 1. ProjectMap (Сканер структуры)
cat > Bosun/Services/Index/ProjectMap.swift <<'SWIFT'
import Foundation

actor ProjectMap {
    private let rootURL: URL
    
    init(rootURL: URL) {
        self.rootURL = rootURL
    }
    
    /// Возвращает текстовое дерево проекта (исключая мусор)
    func buildTree() async -> String {
        var result = "\(rootURL.lastPathComponent)/\n"
        let children = await getChildren(of: rootURL)
        result += formatTree(nodes: children, prefix: "")
        return result
    }
    
    private struct Node {
        let url: URL
        let isDirectory: Bool
        let children: [Node]
    }
    
    private func getChildren(of url: URL) async -> [Node] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        
        var nodes: [Node] = []
        for fileURL in contents {
            let name = fileURL.lastPathComponent
            if ExcludedPaths.names.contains(name) { continue }
            if name.hasPrefix(".") { continue } // пропускаем скрытые
            
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let children = await getChildren(of: fileURL)
                nodes.append(Node(url: fileURL, isDirectory: true, children: children))
            } else {
                nodes.append(Node(url: fileURL, isDirectory: false, children: []))
            }
        }
        
        // Сортировка: папки сверху, потом файлы, по алфавиту
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }
    
    private func formatTree(nodes: [Node], prefix: String) -> String {
        var result = ""
        for (index, node) in nodes.enumerated() {
            let isLast = index == nodes.count - 1
            let branch = isLast ? "└── " : "├── "
            let name = node.url.lastPathComponent + (node.isDirectory ? "/" : "")
            result += prefix + branch + name + "\n"
            
            if node.isDirectory {
                let newPrefix = prefix + (isLast ? "    " : "│   ")
                result += formatTree(nodes: node.children, prefix: newPrefix)
            }
        }
        return result
    }
}
SWIFT

# 2. Обновляем PromptBuilder
cat > Bosun/Services/Agent/PromptBuilder.swift <<'SWIFT'
import Foundation

struct PromptBuilder {
    static func buildSystemPrompt(tree: String?) -> String {
        var prompt = """
        Ты — Bosun, полезный ИИ-ассистент для разработки на macOS.
        Ты работаешь внутри проекта пользователя.
        
        """
        
        if let tree = tree {
            prompt += """
            Структура проекта:
            \(tree)
            
            """
        }
        
        prompt += """
        У тебя есть инструменты для чтения файлов и поиска по коду.
        ВАЖНО: Если тебе нужно изменить или прочитать несколько файлов, 
        вызывай инструменты ПАРАЛЛЕЛЬНО (в одном сообщении). 
        Не жди результата первого вызова, чтобы сделать второй, если они независимы.
        
        Всегда проверяй код перед тем, как предлагать изменения.
        Отвечай кратко и по делу.
        """
        
        return prompt
    }
}
SWIFT

# 3. Обновляем AgentCore (Внедряем карту и системный промпт)
cat > Bosun/Services/Agent/AgentCore.swift <<'SWIFT'
import Foundation

actor AgentCore {
    private let client: OpenRouterClient
    private let runtime: ToolRuntime?
    private let model: String
    private let projectMap: ProjectMap?
    private let approvalHandler: @Sendable ([ApprovalRequest]) async -> Bool
    
    init(
        client: OpenRouterClient,
        runtime: ToolRuntime?,
        model: String,
        projectMap: ProjectMap?,
        approvalHandler: @Sendable @escaping ([ApprovalRequest]) async -> Bool
    ) {
        self.client = client
        self.runtime = runtime
        self.model = model
        self.projectMap = projectMap
        self.approvalHandler = approvalHandler
    }
    
    func run(history: [ChatMessage]) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // 1. Строим дерево проекта
                let tree = await projectMap?.buildTree()
                let systemPrompt = PromptBuilder.buildSystemPrompt(tree: tree)
                
                // 2. Формируем историю: System + User/Assistant...
                var messages: [ChatMessage] = []
                messages.append(ChatMessage(role: .system, content: systemPrompt))
                messages.append(contentsOf: history)
                
                let tools = await runtime?.openRouterTools ?? []
                let useTools = !tools.isEmpty
                
                for _ in 0..<8 { // Увеличили лимит, так как карта дает больше автономности
                    var accumulatedText = ""
                    var accumulatedToolCalls: [ToolCall] = []
                    
                    do {
                        let stream = try await client.streamCompletion(
                            model: model, 
                            messages: messages, 
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
                            if chunk.isDone { break }
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    
                    if accumulatedToolCalls.isEmpty {
                        if !accumulatedText.isEmpty {
                            messages.append(ChatMessage(role: .assistant, content: accumulatedText))
                        }
                        continuation.finish()
                        return
                    }
                    
                    let assistantMsg = ChatMessage(role: .assistant, content: accumulatedText, toolCalls: accumulatedToolCalls)
                    messages.append(assistantMsg)
                    
                    if let runtime = runtime {
                        let requests = await runtime.prepareApprovals(for: accumulatedToolCalls)
                        var approved = true
                        
                        if !requests.isEmpty {
                            approved = await approvalHandler(requests)
                        }
                        
                        for call in accumulatedToolCalls {
                            continuation.yield(.toolCallStarted(call))
                            let result: ToolResult
                            if approved {
                                result = await runtime.execute(call)
                            } else {
                                result = ToolResult.error(call.id, "Пользователь отклонил изменения.")
                            }
                            
                            continuation.yield(.toolResult(result))
                            messages.append(ChatMessage(role: .tool, content: result.content, toolCallId: result.toolCallId))
                        }
                    } else {
                        for call in accumulatedToolCalls {
                            continuation.yield(.toolCallStarted(call))
                            let result = ToolResult.error(call.id, "Инструменты недоступны")
                            continuation.yield(.toolResult(result))
                            messages.append(ChatMessage(role: .tool, content: result.content, toolCallId: result.toolCallId))
                        }
                    }
                }
                
                continuation.finish(throwing: NSError(domain: "Agent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Превышен лимит вызовов (8)"]))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
SWIFT

# 4. Обновляем AppEnvironment (Добавляем ProjectMap)
cat > Bosun/App/AppEnvironment.swift <<'SWIFT'
import Foundation
import Observation

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
    
    var projectRoot: URL? {
        didSet {
            if let root = projectRoot {
                let box = Sandbox(rootURL: root)
                let idx = SymbolIndex(rootURL: root)
                let map = ProjectMap(rootURL: root)
                
                self.sandbox = box
                self.symbolIndex = idx
                self.projectMap = map
                
                let tools: [AgentTool] = [
                    ListDirTool(sandbox: box),
                    ReadFileTool(sandbox: box),
                    SearchTool(sandbox: box),
                    FindSymbolTool(index: idx),
                    ListSymbolsTool(sandbox: box, index: idx),
                    WriteFileTool(sandbox: box),
                    EditFileTool(sandbox: box)
                ]
                self.toolRuntime = ToolRuntime(registry: ToolRegistry(tools: tools))
                settings.projectRootPath = root.path
                
                Task { try? await idx.rebuild() }
            } else {
                sandbox = nil
                symbolIndex = nil
                projectMap = nil
                toolRuntime = nil
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

        if self.keychain.loadAPIKey() == nil {
            self.settings.hasAPIKey = false
        }

        if let path = settings.projectRootPath {
            self.projectRoot = URL(fileURLWithPath: path)
        }
    }
}
SWIFT

# 5. Обновляем ChatViewModel (Передаем projectMap)
cat > Bosun/ViewModels/ChatViewModel.swift <<'SWIFT'
import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    var draft: String = ""
    var messages: [ChatMessage] = []
    var streamingText: String = ""
    var isRunning: Bool = false
    var error: String?
    var selectedModelId: String?
    
    var activeToolCalls: [ToolCall] = []
    var completedToolCalls: [ToolResult] = []
    
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
        !isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedModelId != nil
    }

    func send(toolRuntime: ToolRuntime?, projectMap: ProjectMap?) {
        guard canSend, let model = selectedModelId else { return }
        
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        error = nil
        streamingText = ""
        activeToolCalls = []
        completedToolCalls = []
        pendingApprovals = []
        
        messages.append(ChatMessage(role: .user, content: text))
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
        let history = messages

        currentTask = Task {
            var textBuffer = ""
            
            do {
                let stream = try await core.run(history: history)
                
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .textDelta(let delta):
                        textBuffer += delta
                        await MainActor.run { self.streamingText = textBuffer }
                        
                    case .toolCallStarted(let call):
                        await MainActor.run {
                            self.messages.append(ChatMessage(role: .assistant, content: textBuffer, toolCalls: [call]))
                            textBuffer = ""
                            self.streamingText = ""
                            self.activeToolCalls.append(call)
                        }
                        
                    case .toolResult(let res):
                        await MainActor.run {
                            self.activeToolCalls.removeAll { $0.id == res.toolCallId }
                            self.completedToolCalls.append(res)
                        }
                    case .done:
                        break
                    case .failed(let msg):
                        await MainActor.run { self.error = msg }
                    default:
                        break
                    }
                }
                
                await MainActor.run {
                    if !textBuffer.isEmpty {
                        self.messages.append(ChatMessage(role: .assistant, content: textBuffer))
                    }
                    self.streamingText = ""
                    self.isRunning = false
                }
            } catch {
                await MainActor.run {
                    if !textBuffer.isEmpty {
                        self.messages.append(ChatMessage(role: .assistant, content: textBuffer))
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

# 6. Обновляем Composer (Передаем projectMap)
cat > Bosun/Views/Chat/Composer.swift <<'SWIFT'
import SwiftUI

struct Composer: View {
    @Bindable var vm: ChatViewModel
    var env: AppEnvironment
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
                    .onSubmit { vm.send(toolRuntime: env.toolRuntime, projectMap: env.projectMap) }
                
                if vm.isRunning && vm.streamingText.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 4)
                }
                
                Button {
                    vm.send(toolRuntime: env.toolRuntime, projectMap: env.projectMap)
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

echo "S4: Project Map и системный промпт готовы."
