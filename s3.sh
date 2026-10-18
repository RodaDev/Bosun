#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

mkdir -p Bosun/Services/Tools/Mutating
mkdir -p Bosun/Views/Chat

# 1. Обновляем AgentTool (добавляем флаг мутирующего инструмента)
cat > Bosun/Services/Tools/AgentTool.swift <<'SWIFT'
import Foundation

struct ToolParameter: Codable, Sendable {
    let type: String
    let description: String
    let `enum`: [String]?
    
    init(type: String = "string", description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enum = enumValues
    }
    
    enum CodingKeys: String, CodingKey {
        case type, description
        case `enum`
    }
}

struct ToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let parameters: [String: ToolParameter]
}

protocol AgentTool: Sendable {
    var definition: ToolDefinition { get }
    var requiresApproval: Bool { get }
    func execute(arguments: String) async throws -> String
}

extension AgentTool {
    // По умолчанию read-only
    var requiresApproval: Bool { false }
    
    func decodeArgs<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "Tool", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF8 in arguments"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
SWIFT

# 2. WriteFileTool
cat > Bosun/Services/Tools/Mutating/WriteFileTool.swift <<'SWIFT'
import Foundation

struct WriteFileTool: AgentTool {
    let sandbox: Sandbox
    
    var requiresApproval: Bool { true }
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "write_file",
            description: "Создает новый файл или ПОЛНОСТЬЮ перезаписывает существующий. Внимание: старые данные будут стерты.",
            parameters: [
                "path": ToolParameter(description: "Путь к файлу"),
                "content": ToolParameter(description: "Полное содержимое файла")
            ]
        )
    }
    
    struct Args: Decodable {
        let path: String
        let content: String
    }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let url = try await sandbox.resolve(args.path)
        
        try args.content.write(to: url, atomically: true, encoding: .utf8)
        return "Файл \(args.path) успешно записан."
    }
}
SWIFT

# 3. EditFileTool (Точечная замена)
cat > Bosun/Services/Tools/Mutating/EditFileTool.swift <<'SWIFT'
import Foundation

struct EditFileTool: AgentTool {
    let sandbox: Sandbox
    
    var requiresApproval: Bool { true }
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "edit_file",
            description: "Заменяет конкретный фрагмент текста в файле. Идеально для правок. 'old_string' должен точно совпадать с текстом в файле и быть уникальным.",
            parameters: [
                "path": ToolParameter(description: "Путь к файлу"),
                "old_string": ToolParameter(description: "Точный текст, который нужно найти и заменить"),
                "new_string": ToolParameter(description: "Новый текст, на который нужно заменить")
            ]
        )
    }
    
    struct Args: Decodable {
        let path: String
        let old_string: String
        let new_string: String
    }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let url = try await sandbox.resolve(args.path)
        try await sandbox.validateExists(url)
        
        var content = try String(contentsOf: url, encoding: .utf8)
        
        // Проверка на уникальность
        let occurrences = content.components(separatedBy: args.old_string).count - 1
        if occurrences == 0 {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Строка old_string не найдена в файле."])
        }
        if occurrences > 1 {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Строка old_string встречается \(occurrences) раз. Нужен более уникальный фрагмент."])
        }
        
        content = content.replacingOccurrences(of: args.old_string, with: args.new_string)
        try content.write(to: url, atomically: true, encoding: .utf8)
        
        return "Файл \(args.path) успешно изменен."
    }
}
SWIFT

# 4. Обновляем ToolRuntime (Добавляем Approval Handler)
cat > Bosun/Services/Tools/ToolRuntime.swift <<'SWIFT'
import Foundation

struct ApprovalRequest: Identifiable, Sendable {
    let id: UUID = UUID()
    let toolName: String
    let path: String
    let oldContent: String?
    let newContent: String
}

actor ToolRuntime {
    private let registry: ToolRegistry
    
    init(registry: ToolRegistry) {
        self.registry = registry
    }
    
    var openRouterTools: [[String: Any]] {
        registry.openRouterSchema
    }
    
    /// Выполняет инструмент. Для мутирующих вызывает approvalClosure перед записью.
    func execute(
        _ call: ToolCall,
        approvalClosure: @Sendable @escaping (ApprovalRequest) async -> Bool
    ) async -> ToolResult {
        guard let tool = registry.get(call.function.name) else {
            return ToolResult.error(call.id, "Инструмент '\(call.function.name)' не найден")
        }
        
        do {
            // Если инструмент мутирующий — нужно подтверждение
            if tool.requiresApproval {
                let req = try await prepareApprovalRequest(call: call, tool: tool)
                let approved = await approvalClosure(req)
                if !approved {
                    return ToolResult.error(call.id, "Пользователь отклонил изменения.")
                }
            }
            
            let output = try await tool.execute(arguments: call.function.arguments)
            return ToolResult(toolCallId: call.id, content: output, isError: false)
        } catch {
            return ToolResult.error(call.id, error.localizedDescription)
        }
    }
    
    private func prepareApprovalRequest(call: ToolCall, tool: AgentTool) async throws -> ApprovalRequest {
        let data = call.function.arguments.data(using: .utf8)!
        
        if tool.definition.name == "edit_file" {
            struct Args: Decodable { let path: String, old_string: String, new_string: String }
            let args = try JSONDecoder().decode(Args.self, from: data)
            return ApprovalRequest(toolName: "edit_file", path: args.path, oldContent: args.old_string, newContent: args.new_string)
        } else if tool.definition.name == "write_file" {
            struct Args: Decodable { let path: String, content: String }
            let args = try JSONDecoder().decode(Args.self, from: data)
            // Для write_file нет "старого" текста (он перезаписывает), поэтому oldContent nil
            return ApprovalRequest(toolName: "write_file", path: args.path, oldContent: nil, newContent: args.content)
        }
        
        throw NSError(domain: "Runtime", code: 0, userInfo: [NSLocalizedDescriptionKey: "Неизвестный мутирующий инструмент"])
    }
}
SWIFT

# 5. Обновляем AgentCore (Пробрасываем approvalHandler)
cat > Bosun/Services/Agent/AgentCore.swift <<'SWIFT'
import Foundation

actor AgentCore {
    private let client: OpenRouterClient
    private let runtime: ToolRuntime?
    private let model: String
    private let approvalHandler: @Sendable (ApprovalRequest) async -> Bool
    
    init(
        client: OpenRouterClient,
        runtime: ToolRuntime?,
        model: String,
        approvalHandler: @Sendable @escaping (ApprovalRequest) async -> Bool
    ) {
        self.client = client
        self.runtime = runtime
        self.model = model
        self.approvalHandler = approvalHandler
    }
    
    func run(history: [ChatMessage]) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var messages = history
                let tools = await runtime?.openRouterTools ?? []
                let useTools = !tools.isEmpty
                
                for _ in 0..<5 {
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
                    
                    for call in accumulatedToolCalls {
                        continuation.yield(.toolCallStarted(call))
                        
                        if let runtime = runtime {
                            let result = await runtime.execute(call, approvalClosure: approvalHandler)
                            continuation.yield(.toolResult(result))
                            let toolMsg = ChatMessage(role: .tool, content: result.content, toolCallId: result.toolCallId)
                            messages.append(toolMsg)
                        } else {
                            let result = ToolResult.error(call.id, "Инструменты недоступны")
                            continuation.yield(.toolResult(result))
                            let toolMsg = ChatMessage(role: .tool, content: result.content, toolCallId: result.toolCallId)
                            messages.append(toolMsg)
                        }
                    }
                }
                
                continuation.finish(throwing: NSError(domain: "Agent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Превышен лимит вызовов (5)"]))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
SWIFT

# 6. DiffView (Отображение разницы)
cat > Bosun/Views/Chat/DiffView.swift <<'SWIFT'
import SwiftUI

struct DiffView: View {
    let oldContent: String?
    let newContent: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let old = oldContent {
                Text(old)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.8))
                    .cornerRadius(4)
            }
            
            Text(newContent)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.8))
                .cornerRadius(4)
        }
        .padding()
    }
}
SWIFT

# 7. ApprovalSheet (Окно подтверждения)
cat > Bosun/Views/Chat/ApprovalSheet.swift <<'SWIFT'
import SwiftUI

struct ApprovalSheet: View {
    let request: ApprovalRequest
    let onApprove: () -> Void
    let onReject: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Подтверждение изменений").font(.headline)
            }
            
            Text("Агент хочет изменить файл: \(request.path)")
                .font(.subheadline)
            
            ScrollView {
                DiffView(oldContent: request.oldContent, newContent: request.newContent)
            }
            .frame(maxHeight: 300)
            .background(Color.black.opacity(0.1))
            .cornerRadius(8)
            
            HStack {
                Spacer()
                Button("Отклонить", role: .destructive) { onReject() }
                Button("Применить") { onApprove() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}
SWIFT

# 8. Обновляем ChatViewModel (Ловим Approval)
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
    
    // Состояние для ожидания подтверждения
    var pendingApproval: ApprovalRequest?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    
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

    func send(toolRuntime: ToolRuntime?) {
        guard canSend, let model = selectedModelId else { return }
        
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        error = nil
        streamingText = ""
        activeToolCalls = []
        completedToolCalls = []
        pendingApproval = nil
        
        messages.append(ChatMessage(role: .user, content: text))
        isRunning = true

        let core = AgentCore(
            client: client,
            runtime: toolRuntime,
            model: model,
            approvalHandler: { [weak self] req in
                guard let self = self else { return false }
                return await self.requestApproval(req)
            }
        )
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
        resolveApproval(approved: false) // Отклоняем висящий запрос
    }
    
    // MARK: - Approval Logic
    
    private func requestApproval(_ req: ApprovalRequest) async -> Bool {
        return await withCheckedContinuation { continuation in
            self.pendingApproval = req
            self.approvalContinuation = continuation
        }
    }
    
    func resolveApproval(approved: Bool) {
        approvalContinuation?.resume(returning: approved)
        approvalContinuation = nil
        pendingApproval = nil
    }
}
SWIFT

# 9. Обновляем AppEnvironment (Добавляем мутирующие инструменты)
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
    var toolRuntime: ToolRuntime?
    
    var projectRoot: URL? {
        didSet {
            if let root = projectRoot {
                let box = Sandbox(rootURL: root)
                let idx = SymbolIndex(rootURL: root)
                self.sandbox = box
                self.symbolIndex = idx
                
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

# 10. Привязываем ApprovalSheet к ChatView
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
                        
                        ForEach(vm.activeToolCalls) { call in
                            ToolCallCard(call: call, result: nil)
                        }
                        
                        ForEach(vm.completedToolCalls, id: \.toolCallId) { res in
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
        .sheet(item: $vm.pendingApproval) { req in
            ApprovalSheet(
                request: req,
                onApprove: { vm.resolveApproval(approved: true) },
                onReject: { vm.resolveApproval(approved: false) }
            )
        }
    }
}
SWIFT

echo "S3: Безопасное редактирование и Diff готовы."
