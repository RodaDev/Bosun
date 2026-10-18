#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

mkdir -p Bosun/Views/Project Bosun/Views/Chat Bosun/Services/Agent

# 1. Обновляем модели для поддержки tool_calls
cat > Bosun/Models/ChatMessage.swift <<'SWIFT'
import Foundation

enum ChatRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let role: ChatRole
    var content: String
    var toolCalls: [ToolCall]?
    var toolCallId: String?

    init(id: UUID = UUID(), role: ChatRole, content: String, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

extension ChatMessage {
    struct Wire: Codable, Sendable {
        let role: String
        let content: String?
        let tool_calls: [ToolCall]?
        let tool_call_id: String?
    }

    var wire: Wire {
        Wire(role: role.rawValue, content: content.isEmpty ? nil : content, tool_calls: toolCalls, tool_call_id: toolCallId)
    }
}

struct ChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage.Wire]
    let stream: Bool
    let tools: [[String: AnyCodable]]?
}

// Хак для кодирования словаря [String: Any] в Encodable
struct AnyCodable: Encodable, Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? String { try container.encode(v) }
        else if let v = value as? Int { try container.encode(v) }
        else if let v = value as? Bool { try container.encode(v) }
        else if let v = value as? [String: Any] {
            try container.encode(v.mapValues { AnyCodable($0) })
        }
        else if let v = value as? [Any] {
            try container.encode(v.map { AnyCodable($0) })
        }
        else { try container.encodeNil() }
    }
}
SWIFT

# 2. ProjectTreeView (Кнопка выбора проекта)
cat > Bosun/Views/Project/ProjectTreeView.swift <<'SWIFT'
import SwiftUI
import AppKit

struct ProjectTreeView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack {
            if let root = env.projectRoot {
                List {
                    Text(root.lastPathComponent)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Button("Сменить проект") { selectFolder() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .listStyle(.sidebar)
            } else {
                Spacer()
                Text("Проект не выбран")
                    .foregroundStyle(.secondary)
                Button("Открыть проект") { selectFolder() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top)
                Spacer()
            }
        }
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            env.projectRoot = url
        }
    }
}
SWIFT

# 3. PromptBuilder
cat > Bosun/Services/Agent/PromptBuilder.swift <<'SWIFT'
import Foundation

struct PromptBuilder {
    static func buildSystemPrompt() -> String {
        return """
        Ты — Bosun, полезный ИИ-ассистент для разработки на macOS.
        Ты работаешь внутри проекта пользователя.
        У тебя есть инструменты для чтения файлов и поиска по коду.
        
        Если тебе нужно посмотреть код, используй инструменты (list_dir, read_file, search, find_symbol).
        Всегда проверяй код перед тем, как предлагать изменения.
        Отвечай кратко и по делу.
        """
    }
}
SWIFT

# 4. AgentCore (Мозг)
cat > Bosun/Services/Agent/AgentCore.swift <<'SWIFT'
import Foundation

actor AgentCore {
    private let client: OpenRouterClient
    private let runtime: ToolRuntime
    private let model: String
    
    init(client: OpenRouterClient, runtime: ToolRuntime, model: String) {
        self.client = client
        self.runtime = runtime
        self.model = model
    }
    
    func run(history: [ChatMessage]) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var messages = history
                let tools = await runtime.openRouterTools
                
                // Защита от бесконечного цикла (максимум 5 итераций инструментов)
                for _ in 0..<5 {
                    var accumulatedText = ""
                    var accumulatedToolCalls: [ToolCall] = []
                    
                    do {
                        let stream = try await client.streamCompletion(model: model, messages: messages, tools: tools)
                        
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
                    
                    // Если инструментов нет — модель закончила
                    if accumulatedToolCalls.isEmpty {
                        if !accumulatedText.isEmpty {
                            messages.append(ChatMessage(role: .assistant, content: accumulatedText))
                        }
                        continuation.finish()
                        return
                    }
                    
                    // Добавляем ответ ассистента с tool_calls в историю
                    let assistantMsg = ChatMessage(role: .assistant, content: accumulatedText, toolCalls: accumulatedToolCalls)
                    messages.append(assistantMsg)
                    
                    // Выполняем инструменты
                    for call in accumulatedToolCalls {
                        continuation.yield(.toolCallStarted(call))
                        let result = await runtime.execute(call)
                        continuation.yield(.toolResult(result))
                        
                        let toolMsg = ChatMessage(role: .tool, content: result.content, toolCallId: result.toolCallId)
                        messages.append(toolMsg)
                    }
                }
                
                // Если вышли из цикла (превышен лимит)
                continuation.finish(throwing: NSError(domain: "Agent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Превышен лимит вызовов инструментов (5)"]))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
SWIFT

# 5. Обновляем OpenRouterClient (парсинг tool_calls)
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

struct StreamChunk: Sendable {
    var textDelta: String = ""
    var toolCalls: [ToolCall]? = nil
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
            tools: tools?.map { dict in
                AnyCodable(dict)
            }
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
                            if payload == "[DONE]" {
                                // Собираем накопленные tool_calls
                                let sortedCalls = toolCallBuilders.sorted { $0.key < $1.key }.map { (_, builder) in
                                    ToolCall(id: builder.id, type: "function", function: ToolCall.Function(name: builder.name, arguments: builder.args))
                                }
                                if !sortedCalls.isEmpty {
                                    continuation.yield(StreamChunk(toolCalls: sortedCalls))
                                }
                                continuation.yield(StreamChunk(isDone: true))
                                continuation.finish()
                                return
                            }
                            
                            if let data = payload.data(using: .utf8),
                               let chunk = try? JSONDecoder().decode(WireChunk.self, from: data) {
                                
                                if let text = chunk.choices?.first?.delta?.content, !text.isEmpty {
                                    continuation.yield(StreamChunk(textDelta: text))
                                }
                                
                                if let tcs = chunk.choices?.first?.delta?.tool_calls {
                                    for tc in tcs {
                                        var builder = toolCallBuilders[tc.index] ?? (id: tc.id ?? UUID().uuidString, name: "", args: "")
                                        if let n = tc.function?.name, !n.isEmpty { builder.name = n }
                                        if let a = tc.function?.arguments { builder.args += a }
                                        toolCallBuilders[tc.index] = builder
                                    }
                                }
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

    private func apiKey() throws -> String {
        guard let key = keychain.loadAPIKey(), !key.isEmpty else {
            throw OpenRouterError.missingAPIKey
        }
        return key
    }

    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var out = Data()
        for try await d in stream { out.append(d) }
        return out
    }
}

// Структуры для парсинга ответа (WireChunk)
struct WireChunk: Decodable {
    let choices: [Choice]?
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
}
SWIFT

# 6. Обновляем ChatViewModel
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
    
    // Для UI карточек инструментов
    var activeToolCalls: [ToolCall] = []
    var completedToolCalls: [ToolResult] = []
    
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

    func send(env: AppEnvironment) {
        guard canSend, let model = selectedModelId, let toolRuntime = env.toolRuntime else { return }
        
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        error = nil
        streamingText = ""
        activeToolCalls = []
        completedToolCalls = []
        
        messages.append(ChatMessage(role: .user, content: text))
        isRunning = true

        let core = AgentCore(client: client, runtime: toolRuntime, model: model)
        let history = messages

        currentTask = Task {
            do {
                let stream = try await core.run(history: history)
                var textBuffer = ""
                
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .textDelta(let delta):
                        textBuffer += delta
                        await MainActor.run { self.streamingText = textBuffer }
                    case .toolCallStarted(let call):
                        await MainActor.run { self.activeToolCalls.append(call) }
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
    }
}
SWIFT

# 7. ToolCallCard View
cat > Bosun/Views/Chat/ToolCallCard.swift <<'SWIFT'
import SwiftUI

struct ToolCallCard: View {
    let call: ToolCall
    let result: ToolResult?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: result == nil ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                    .foregroundStyle(result == nil ? .orange : .green)
                Text("\(call.function.name)()")
                    .font(.system(.callout, design: .monospaced))
                    .bold()
                Spacer()
                if result == nil {
                    ProgressView().controlSize(.small)
                }
            }
            
            Text(call.function.arguments)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
SWIFT

# 8. Обновляем ChatView (Внедряем env и карточки)
cat > Bosun/Views/Chat/ChatView.swift <<'SWIFT'
import SwiftUI

struct ChatView: View {
    @Bindable var vm: ChatViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.messages) { MessageBubble(message: $0).id($0.id) }
                        
                        // Активные вызовы
                        ForEach(vm.activeToolCalls) { call in
                            ToolCallCard(call: call, result: nil)
                        }
                        
                        // Завершенные вызовы
                        ForEach(vm.completedToolCalls, id: \.toolCallId) { res in
                            // (В реальном проекте мы бы связали call и result по id, 
                            // здесь для простоты покажем заглушку, если не нашли call)
                            if let call = vm.messages.last(where: { $0.toolCalls?.contains(where: { $0.id == res.toolCallId }) == true })?.toolCalls?.first(where: { $0.id == res.toolCallId }) {
                                ToolCallCard(call: call, result: res)
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
                Text("Выберите проект слева, чтобы агент мог использовать инструменты.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }

            Composer(vm: vm, env: env)
        }
    }
}
SWIFT

# 9. Обновляем Composer (Передаем env)
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
                    .onSubmit { vm.send(env: env) }
                Button {
                    vm.send(env: env)
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

echo "S2c: Агент и UI готовы."
