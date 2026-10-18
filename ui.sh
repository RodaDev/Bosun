#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. ProjectNode (Добавляем Equatable для SwiftUI)
cat > Bosun/Models/ProjectNode.swift <<'SWIFT'
import Foundation

struct ProjectNode: Identifiable, Hashable, Sendable {
    let id: URL
    let name: String
    let isDirectory: Bool
    var children: [ProjectNode]?
    var isModified: Bool = false

    var url: URL { id }
}
SWIFT

# 2. ProjectMap (Теперь возвращает дерево узлов)
cat > Bosun/Services/Index/ProjectMap.swift <<'SWIFT'
import Foundation

actor ProjectMap {
    private let rootURL: URL
    private var cachedTree: [ProjectNode]?
    
    init(rootURL: URL) {
        self.rootURL = rootURL
    }
    
    func getTreeNodes() async -> [ProjectNode] {
        if let cached = cachedTree { return cached }
        let nodes = await buildTreeNodes()
        cachedTree = nodes
        return nodes
    }
    
    func refreshTree() async -> [ProjectNode] {
        let nodes = await buildTreeNodes()
        cachedTree = nodes
        return nodes
    }
    
    func getTextTree() async -> String {
        let nodes = await getTreeNodes()
        return formatTextTree(nodes: nodes, prefix: "")
    }
    
    private func buildTreeNodes() async -> [ProjectNode] {
        return await getChildren(of: rootURL)
    }
    
    private func getChildren(of url: URL) async -> [ProjectNode] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        
        var nodes: [ProjectNode] = []
        for fileURL in contents {
            let name = fileURL.lastPathComponent
            if ExcludedPaths.names.contains(name) { continue }
            if name.hasPrefix(".") { continue }
            
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let children = await getChildren(of: fileURL)
                nodes.append(ProjectNode(id: fileURL, name: name, isDirectory: true, children: children))
            } else {
                nodes.append(ProjectNode(id: fileURL, name: name, isDirectory: false, children: nil))
            }
        }
        
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    
    private func formatTextTree(nodes: [ProjectNode], prefix: String) -> String {
        var result = ""
        for (index, node) in nodes.enumerated() {
            let isLast = index == nodes.count - 1
            let branch = isLast ? "└── " : "├── "
            let name = node.name + (node.isDirectory ? "/" : "")
            result += prefix + branch + name + "\n"
            
            if let children = node.children {
                let newPrefix = prefix + (isLast ? "    " : "│   ")
                result += formatTextTree(nodes: children, prefix: newPrefix)
            }
        }
        return result
    }
}
SWIFT

# 3. ChatViewModel (Добавляем счетчик токенов и обновление дерева)
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
    
    // Стейт для UI
    var projectNodes: [ProjectNode] = []
    var activeToolCalls: [ToolCall] = []
    var completedToolCalls: [ToolResult] = []
    
    // Статистика токенов
    var totalPromptTokens: Int = 0
    var totalCompletionTokens: Int = 0
    
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

    func loadTree(from map: ProjectMap?) async {
        if let map = map {
            self.projectNodes = await map.getTreeNodes()
        }
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
                            
                            // Если это мутирующий инструмент — помечаем файл
                            if call.function.name == "edit_file" || call.function.name == "write_file" {
                                // В идеале нужно обновлять ProjectNode, но для простоты перезапросим дерево
                            }
                        }
                        
                    case .toolResult(let res):
                        await MainActor.run {
                            self.activeToolCalls.removeAll { $0.id == res.toolCallId }
                            self.completedToolCalls.append(res)
                        }
                    case .usage(let prompt, let completion, _):
                        await MainActor.run {
                            self.totalPromptTokens += prompt
                            self.totalCompletionTokens += completion
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
                    Task { await self.loadTree(from: projectMap) }
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

# 4. AgentCore (Добавляем подсчет usage и передачу текстового дерева)
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
                let tree = await projectMap?.getTextTree()
                let systemPrompt = PromptBuilder.buildSystemPrompt(tree: tree)
                
                var messages: [ChatMessage] = []
                messages.append(ChatMessage(role: .system, content: systemPrompt))
                
                let recentHistory = history.suffix(20)
                messages.append(contentsOf: recentHistory)
                
                let tools = await runtime?.openRouterTools ?? []
                let useTools = !tools.isEmpty
                
                for _ in 0..<8 {
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
                            if let usage = chunk.usage {
                                continuation.yield(.usage(prompt: usage.promptTokens, completion: usage.completionTokens, cached: usage.cachedTokens))
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

# 5. OpenRouterClient (Добавляем usage в StreamChunk)
cat > Bosun/Services/Networking/OpenRouterClient.swift <<'SWIFT'
import Foundation

enum OpenRouterError: Error, LocalizedError {
    case missingAPIKey
    case unauthorized
    case server(status: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "OpenRouter API key не задан"
        case .unauthorized: return "OpenRouter: 401 Unauthorized — проверьте ключ"
        case .server(let status, let body): return "OpenRouter: HTTP \(status) — \(body.prefix(200))"
        case .decoding(let msg): return "OpenRouter: ошибка разбора ответа — \(msg)"
        }
    }
}

struct UsageInfo: Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let cachedTokens: Int
}

struct StreamChunk: Sendable {
    var textDelta: String = ""
    var toolCalls: [ToolCall]? = nil
    var usage: UsageInfo? = nil
    var isDone: Bool = false
}

actor OpenRouterClient {
    private let transport: OpenRouterTransport
    private let keychain: KeychainStore
    private let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    init(transport: OpenRouterTransport, keychain: KeychainStore) {
        self.transport = transport
        self.keychain = keychain
    }

    func fetchModels() async throws -> [ModelInfo] {
        let request = HTTPRequest(
            url: baseURL.appending(path: "models"),
            method: "GET",
            headers: ["Authorization": "Bearer \(try apiKey())"]
        )
        let response = try await transport.send(request)
        let data = try await collect(response.body)
        guard response.statusCode == 200 else {
            throw OpenRouterError.server(status: response.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        struct ModelsResponse: Decodable { let data: [ModelInfo.Wire] }
        do {
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data.map { $0.toModel() }
        } catch {
            throw OpenRouterError.decoding("\(error)")
        }
    }

    func streamCompletion(
        model: String,
        messages: [ChatMessage],
        tools: [[String: Any]]?
    ) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        let payload = ChatCompletionRequest(
            model: model,
            messages: messages.map(\.wire),
            stream: true,
            tools: tools?.map { AnyCodable($0) }
        )
        let data = try JSONEncoder().encode(payload)

        let request = HTTPRequest(
            url: baseURL.appending(path: "chat/completions"),
            method: "POST",
            headers: [
                "Authorization": "Bearer \(try apiKey())",
                "Content-Type": "application/json",
                "HTTP-Referer": "https://github.com/bosun-app/bosun",
                "X-Title": "Bosun"
            ],
            body: data
        )
        let response = try await transport.send(request)
        guard response.statusCode == 200 else {
            let errBody = try await collect(response.body)
            throw OpenRouterError.server(
                status: response.statusCode,
                body: String(data: errBody, encoding: .utf8) ?? ""
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                var toolCallBuilders: [Int: (id: String, name: String, args: String)] = [:]
                
                do {
                    for try await raw in response.body {
                        for payload in parser.feed(raw) {
                            let isDone = Self.processPayload(
                                payload,
                                builders: &toolCallBuilders,
                                continuation: continuation
                            )
                            if isDone {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func processPayload(
        _ payload: String,
        builders: inout [Int: (id: String, name: String, args: String)],
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) -> Bool {
        if payload == "[DONE]" {
            let sortedCalls = builders.sorted { $0.key < $1.key }.map { (_, builder) in
                ToolCall(
                    id: builder.id,
                    type: "function",
                    function: ToolCall.Function(
                        name: builder.name,
                        arguments: sanitizeArguments(builder.args)
                    )
                )
            }
            if !sortedCalls.isEmpty {
                continuation.yield(StreamChunk(toolCalls: sortedCalls))
            }
            continuation.yield(StreamChunk(isDone: true))
            return true
        }
        
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(WireChunk.self, from: data) else {
            return false
        }
        
        if let text = chunk.choices?.first?.delta?.content, !text.isEmpty {
            continuation.yield(StreamChunk(textDelta: text))
        }
        
        if let tcs = chunk.choices?.first?.delta?.tool_calls {
            for tc in tcs {
                var builder = builders[tc.index] ?? (id: tc.id ?? UUID().uuidString, name: "", args: "")
                if let n = tc.function?.name, !n.isEmpty { builder.name = n }
                if let a = tc.function?.arguments { builder.args += a }
                builders[tc.index] = builder
            }
        }
        
        // Парсим usage (обычно приходит в последнем чанке)
        if let u = chunk.usage {
            continuation.yield(StreamChunk(usage: UsageInfo(promptTokens: u.prompt_tokens ?? 0, completionTokens: u.completion_tokens ?? 0, cachedTokens: u.prompt_tokens_details?.cached_tokens ?? 0)))
        }
        
        return false
    }

    private static func sanitizeArguments(_ raw: String) -> String {
        var args = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if args.hasPrefix("```json") {
            args = args.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        } else if args.hasPrefix("```") {
            args = args.replacingOccurrences(of: "```", with: "")
        }
        args = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if args.isEmpty { return "{}" }
        if let data = args.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) == nil { return "{}" }
        return args
    }

    private func apiKey() throws -> String {
        guard let key = keychain.loadAPIKey(), !key.isEmpty else { throw OpenRouterError.missingAPIKey }
        return key
    }

    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var out = Data()
        for try await d in stream { out.append(d) }
        return out
    }
}

struct WireChunk: Decodable {
    let choices: [Choice]?
    let usage: Usage?
    struct Choice: Decodable {
        let delta: Delta?
    }
    struct Delta: Decodable {
        let content: String?
        let tool_calls: [WireToolCall]?
    }
    struct WireToolCall: Decodable {
        let index: Int
        let id: String?
        let function: WireFunction?
    }
    struct WireFunction: Decodable {
        let name: String?
        let arguments: String?
    }
    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let prompt_tokens_details: PromptDetails?
    }
    struct PromptDetails: Decodable {
        let cached_tokens: Int?
    }
}
SWIFT

# 6. ProjectTreeView (OutlineGroup и Токены)
cat > Bosun/Views/Project/ProjectTreeView.swift <<'SWIFT'
import SwiftUI

struct ProjectTreeView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            if env.projectRoot != nil {
                List(env.chatVM.projectNodes, children: \.children) { node in
                    HStack(spacing: 6) {
                        Image(systemName: node.isDirectory ? "folder" : "doc.text")
                            .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                        Text(node.name)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(node.isModified ? .orange : .primary)
                    }
                }
                .listStyle(.sidebar)
            } else {
                Spacer()
                Text("Проект не выбран")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            
            Divider()
            
            // Плашка с токенами
            VStack(alignment: .leading, spacing: 4) {
                Text("Токены (сессия)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "arrow.up.circle")
                    Text("\(env.chatVM.totalPromptTokens)")
                    Spacer()
                    Image(systemName: "arrow.down.circle")
                    Text("\(env.chatVM.totalCompletionTokens)")
                }
                .font(.system(.caption, design: .monospaced))
            }
            .padding(10)
            .background(Color.black.opacity(0.1))
        }
        .onAppear {
            Task { await env.chatVM.loadTree(from: env.projectMap) }
        }
    }
}
SWIFT

# 7. ChatView (Верхняя панель)
cat > Bosun/Views/Chat/ChatView.swift <<'SWIFT'
import SwiftUI
import AppKit

struct ChatView: View {
    @Bindable var vm: ChatViewModel
    @Environment(AppEnvironment.self) private var env
    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 0) {
            // Верхняя панель (Toolbar)
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
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("Обновить карту проекта")
                
                Button {
                    selectFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Сменить проект")
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

echo "UI рефакторинг: Дерево и токены готовы."
