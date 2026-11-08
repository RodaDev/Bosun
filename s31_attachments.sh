#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Создаем модель вложения
cat > Bosun/Models/ChatAttachment.swift <<'SWIFT'
import Foundation

enum AttachmentType: String, Codable, Sendable {
    case image, text
}

struct ChatAttachment: Identifiable, Hashable, Sendable {
    let id: UUID = UUID()
    let fileName: String
    let type: AttachmentType
    let data: Data
    
    var base64Image: String? {
        guard type == .image else { return nil }
        let mime = fileName.lowercased().hasSuffix("png") ? "image/png" : "image/jpeg"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }
    
    var textContent: String? {
        guard type == .text else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
SWIFT

# 2. Обновляем ChatMessage (Wire формат для Vision API)
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
    var attachments: [ChatAttachment]?

    init(id: UUID = UUID(), role: ChatRole, content: String, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil, attachments: [ChatAttachment]? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.attachments = attachments
    }
}

extension ChatMessage {
    struct Wire: Codable, Sendable {
        let role: String
        let content: [WireContent]?
        let tool_calls: [ToolCall]?
        let tool_call_id: String?
    }
    
    struct WireContent: Codable, Sendable {
        let type: String // "text" or "image_url"
        let text: String?
        let image_url: ImageURL?
        
        struct ImageURL: Codable, Sendable {
            let url: String
        }
    }

    var wire: Wire {
        var parts: [WireContent] = []
        
        // 1. Добавляем вложения (картинки и текст)
        if let atts = attachments {
            for att in atts {
                if att.type == .image, let b64 = att.base64Image {
                    parts.append(WireContent(type: "image_url", text: nil, image_url: .init(url: b64)))
                } else if att.type == .text, let text = att.textContent {
                    parts.append(WireContent(type: "text", text: "Содержимое файла \(att.fileName):\n\(text)\n", image_url: nil))
                }
            }
        }
        
        // 2. Добавляем обычный текст сообщения
        if !content.isEmpty {
            parts.append(WireContent(type: "text", text: content, image_url: nil))
        }
        
        return Wire(
            role: role.rawValue, 
            content: parts.isEmpty ? nil : parts, 
            tool_calls: toolCalls, 
            tool_call_id: toolCallId
        )
    }
}

struct ChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage.Wire]
    let stream: Bool
    let tools: [AnyCodable]?
}

struct AnyCodable: Encodable, Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? String { try container.encode(v) }
        else if let v = value as? Int { try container.encode(v) }
        else if let v = value as? Bool { try container.encode(v) }
        else if let v = value as? [String: Any] { try container.encode(v.mapValues { AnyCodable($0) }) }
        else if let v = value as? [Any] { try container.encode(v.map { AnyCodable($0) }) }
        else { try container.encodeNil() }
    }
}
SWIFT

# 3. Обновляем БД (StoredMessage) для хранения вложений
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
    
    init(title: String = "Новый диалог") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.lastModified = Date()
        self.messages = []
    }
    
    var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastModified, relativeTo: Date())
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
    var attachmentsJson: String? // <-- Храним вложения в JSON
    
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
        if let atts = chatMessage.attachments, let data = try? JSONEncoder().encode(atts) {
            self.attachmentsJson = String(data: data, encoding: .utf8)
        }
    }
    
    func toChatMessage() -> ChatMessage {
        var calls: [ToolCall]? = nil
        if let json = toolCallsJson, let data = json.data(using: .utf8) {
            calls = try? JSONDecoder().decode([ToolCall].self, from: data)
        }
        var atts: [ChatAttachment]? = nil
        if let json = attachmentsJson, let data = json.data(using: .utf8) {
            atts = try? JSONDecoder().decode([ChatAttachment].self, from: data)
        }
        return ChatMessage(
            id: id,
            role: ChatRole(rawValue: role) ?? .user,
            content: content,
            toolCalls: calls,
            toolCallId: toolCallId,
            attachments: atts
        )
    }
}

// Расширяем ChatAttachment для Codable (так как структура теперь должна сохраняться)
extension ChatAttachment: Codable {
    enum CodingKeys: String, CodingKey {
        case id, fileName, type, data
    }
}
SWIFT

# 4. Обновляем ChatViewModel (Добавление файлов)
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
    var pendingAttachments: [ChatAttachment] = [] // <-- Вложения
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
    
    // ДОБАВЛЕНИЕ ФАЙЛА
    func addFile(url: URL) {
        let ext = url.pathExtension.lowercased()
        let isImage = ["png", "jpg", "jpeg", "heic"].contains(ext)
        
        guard let data = try? Data(contentsOf: url) else { return }
        
        // Ограничение размера файла (например, 5 МБ)
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

    func send(toolRuntime: ToolRuntime?, projectMap: ProjectMap?, context: ModelContext) {
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

# 5. Обновляем Composer (UI с кнопкой прикрепления и Drag&Drop)
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
            // Превью вложений
            if !vm.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(vm.pendingAttachments) { att in
                            HStack(spacing: 4) {
                                if att.type == .image {
                                    Image(systemName: "photo").foregroundStyle(.blue)
                                } else {
                                    Image(systemName: "doc.text").foregroundStyle(.orange)
                                }
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
                // Кнопка выбора файла
                Button {
                    selectFile()
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                
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
                    .onSubmit { 
                        Task { vm.send(toolRuntime: env.toolRuntime, projectMap: env.projectMap, context: context) } 
                    }
                
                if vm.isRunning && vm.streamingText.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 4)
                }
                
                Button {
                    Task { vm.send(toolRuntime: env.toolRuntime, projectMap: env.projectMap, context: context) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!vm.canSend)
            }
            .padding(10)
            .background(isTargeted ? Color.accentColor.opacity(0.2) : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .padding(12)
        .sheet(isPresented: $showPicker) { ModelPickerSheet() }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        DispatchQueue.main.async {
                            vm.addFile(url: url)
                        }
                    }
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
            for url in panel.urls {
                vm.addFile(url: url)
            }
        }
    }
}
SWIFT

# 6. Обновляем MessageBubble (Отображение вложений в чате)
cat > Bosun/Views/Chat/MessageBubble.swift <<'SWIFT'
import SwiftUI
import AppKit

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                // Вложения
                if let atts = message.attachments {
                    ForEach(atts) { att in
                        if att.type == .image, let nsImage = NSImage(data: att.data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 300, maxHeight: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            HStack {
                                Image(systemName: "doc.text")
                                Text(att.fileName)
                            }
                            .font(.caption)
                            .padding(6)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                
                // Текст
                if !message.content.isEmpty {
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(background)
                        .foregroundStyle(foreground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var background: some ShapeStyle {
        message.role == .user
            ? AnyShapeStyle(Color.accentColor.opacity(0.15))
            : AnyShapeStyle(Color.secondary.opacity(0.12))
    }
    private var foreground: Color { .primary }
}
SWIFT

echo "S31: Поддержка вложений (Drag&Drop) готова."
