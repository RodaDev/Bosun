#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Обновляем AgentEvent
cat > Bosun/Models/AgentEvent.swift <<'SWIFT'
import Foundation

enum AgentEvent: Sendable {
    case textDelta(String)
    case toolCallStarted(ToolCall)
    case toolResult(ToolResult)
    case usage(prompt: Int, completion: Int, cached: Int)
    case checkpoint([ChatMessage]) // <--- Сохранение контекста
    case done
    case failed(String)
}
SWIFT

# 2. Обновляем PromptBuilder (добавляем суммаризацию)
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
    
    static func buildSummaryPrompt() -> String {
        return """
        Сожми следующий диалог агента и пользователя в краткую сводку.
        Укажи: какие файлы были прочитаны, какие изменения внесены, и какова главная цель задачи.
        Не пиши лишнего, только факты. Максимум 5 предложений.
        """
    }
}
SWIFT

# 3. Обновляем AgentCore (Динамический лимит, Checkpointing, Суммаризация)
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
    
    // Основной цикл
    func run(history: [ChatMessage], sessionContext: [ChatMessage] = []) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let tree = await projectMap?.getTextTree()
                let systemPrompt = PromptBuilder.buildSystemPrompt(tree: tree)
                
                var messages: [ChatMessage] = []
                messages.append(ChatMessage(role: .system, content: systemPrompt))
                
                // Если есть сохраненный контекст сессии (после сбоя), используем его
                if !sessionContext.isEmpty {
                    messages.append(contentsOf: sessionContext)
                } else {
                    // Иначе берем историю UI (сжимаем, если она слишком длинная)
                    let contextToSend = await compressIfNeeded(history: history)
                    messages.append(contentsOf: contextToSend)
                }
                
                let tools = await runtime?.openRouterTools ?? []
                let useTools = !tools.isEmpty
                
                // Динамический лимит: 25 шагов
                for step in 0..<25 {
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
                        // В случае ошибки (например, таймаута) сохраняем контекст
                        continuation.yield(.checkpoint(messages))
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
                    
                    // Сохраняем контекст после каждого успешного шага
                    continuation.yield(.checkpoint(messages))
                    
                    // Защита от зацикливания (если агент 25 раз вызывает один и тот же инструмент)
                    if step == 24 {
                        continuation.yield(.checkpoint(messages))
                        continuation.finish(throwing: NSError(domain: "Agent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Достигнут лимит шагов (25). Вы можете продолжить диалог."]))
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    // Сжатие контекста, если история слишком длинная
    private func compressIfNeeded(history: [ChatMessage]) async -> [ChatMessage] {
        if history.count <= 15 {
            return history
        }
        
        // Берем последние 5 сообщений, остальные суммируем
        let toSummarize = Array(history.prefix(history.count - 5))
        let recent = Array(history.suffix(5))
        
        var summaryText = "Краткая сводка предыдущих действий:\n"
        for msg in toSummarize {
            if msg.role == .user {
                summaryText += "- Пользователь: \(msg.content.prefix(100))\n"
            } else if msg.role == .assistant, !msg.content.isEmpty {
                summaryText += "- Ассистент: \(msg.content.prefix(100))\n"
            } else if msg.role == .tool {
                summaryText += "- Инструмент выполнен.\n"
            }
        }
        
        let summaryMsg = ChatMessage(role: .system, content: summaryText)
        return [summaryMsg] + recent
    }
}
SWIFT

# 4. Обновляем ChatViewModel (Поддержка sessionContext и обработка checkpoint)
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
    
    // Контекст сессии для восстановления
    var sessionContext: [ChatMessage] = []
    
    // Стейт для UI
    var projectNodes: [ProjectNode] = []
    var activeToolCalls: [ToolCall] = []
    var completedToolCalls: [ToolResult] = []
    
    // Статистика токенов
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
        !isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedModelId != nil
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
        } catch {
            print("Ошибка загрузки баланса: \(error)")
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
        
        // Если есть сохраненный контекст (после продолжения), используем его
        let contextToSend = sessionContext
        sessionContext = [] // Очищаем, так как AgentCore его подхватит
        
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
        
        // Если контекста нет, передаем историю UI
        let history = contextToSend.isEmpty ? messages : messages.dropLast()

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
                        
                    case .checkpoint(let msgs):
                        await MainActor.run {
                            self.sessionContext = msgs
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
                    }
                }
                
                await MainActor.run {
                    if !textBuffer.isEmpty {
                        self.messages.append(ChatMessage(role: .assistant, content: textBuffer))
                    }
                    self.streamingText = ""
                    self.isRunning = false
                    Task { await self.loadTree(from: projectMap) }
                    Task { await self.refreshBalance() }
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

echo "S7: Context Management (Checkpointing & Summarization) готов."
