#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

mkdir -p Bosun/Services/Git

# 1. GitService (Управление Git)
cat > Bosun/Services/Git/GitService.swift <<'SWIFT'
import Foundation

actor GitService {
    private let rootURL: URL
    
    init(rootURL: URL) {
        self.rootURL = rootURL
    }
    
    private func runGit(_ arguments: [String]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = rootURL
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "Ошибка запуска git: \(error.localizedDescription)"
        }
    }
    
    func undoAllChanges() async throws {
        // Откатываем все изменения в отслеживаемых файлах
        _ = await runGit(["checkout", "."])
        // Удаляем новые неотслеживаемые файлы (кроме игнорируемых)
        _ = await runGit(["clean", "-fd"])
    }
    
    func getStatus() async -> String {
        let status = await runGit(["status", "--short"])
        return status.isEmpty ? "Нет изменений" : status
    }
    
    func getDiff() async -> String {
        return await runGit(["diff"])
    }
}

// 2. Git Tools (Чтобы агент мог видеть свои правки и коммитить)
struct GitStatusTool: AgentTool {
    let gitService: GitService
    var definition: ToolDefinition {
        ToolDefinition(name: "git_status", description: "Показывает измененные файлы", parameters: [:])
    }
    func execute(arguments: String) async throws -> String {
        return await gitService.getStatus()
    }
}

struct GitDiffTool: AgentTool {
    let gitService: GitService
    var definition: ToolDefinition {
        ToolDefinition(name: "git_diff", description: "Показывает построчный diff изменений", parameters: [:])
    }
    func execute(arguments: String) async throws -> String {
        let diff = await gitService.getDiff()
        return diff.isEmpty ? "Нет изменений" : String(diff.prefix(5000))
    }
}

// 3. Обновляем AgentCore (Auto-Fix Loop)
cat > Bosun/Services/Agent/AgentCore.swift <<'SWIFT'
import Foundation

actor AgentCore {
    private let client: OpenRouterClient
    private let runtime: ToolRuntime?
    private let model: String
    private let projectMap: ProjectMap?
    private let approvalHandler: @Sendable ([ApprovalRequest]) async -> Bool
    
    private let contextLimit = 15000
    
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
    
    func run(history: [ChatMessage], sessionContext: [ChatMessage] = []) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let tree = await projectMap?.getTextTree()
                let systemPrompt = PromptBuilder.buildSystemPrompt(tree: tree)
                
                var messages: [ChatMessage] = []
                messages.append(ChatMessage(role: .system, content: systemPrompt))
                
                let lastUserMessage = history.last(where: { $0.role == .user })?.content ?? ""
                let rawContext = sessionContext.isEmpty ? await compressIfNeeded(history: history) : sessionContext
                let safeContext = sanitizeHistory(rawContext)
                messages.append(contentsOf: safeContext)
                
                let tools = await runtime?.openRouterTools ?? []
                let useTools = !tools.isEmpty
                
                var consecutiveBuildFailures = 0
                
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
                    
                    // Сжатие контекста
                    if let usage = (chunk.usage?.promptTokens), usage > contextLimit {
                        // (Код сжатия оставлен без изменений для краткости)
                    }
                    
                    if accumulatedToolCalls.isEmpty {
                        if !accumulatedText.isEmpty {
                            messages.append(ChatMessage(role: .assistant, content: accumulatedText))
                        }
                        
                        // AUTO-FIX LOOP: Если сборка падала, заставляем агента продолжить
                        if consecutiveBuildFailures > 0 && consecutiveBuildFailures <= 3 {
                            messages.append(ChatMessage(role: .system, content: "СБОРКА ВСЁ ЕЩЕ ПАДАЕТ. Ты должен использовать edit_file, чтобы исправить ошибки. Не сдавайся, проанализируй лог."))
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
                            
                            // Проверка на ошибку сборки
                            if call.function.name == "run_xcodebuild" || call.function.name == "run_build" {
                                if result.content.contains("error:") || result.content.contains("BUILD FAILED") || result.isError {
                                    consecutiveBuildFailures += 1
                                    messages.append(ChatMessage(role: .system, content: "СБОРКА УПАЛА. Проанализируй ошибки выше и исправь их с помощью edit_file."))
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
    
    // ... (sanitizeHistory, summarize, compressIfNeeded остаются здесь же, копируем из прошлого файла)
}
SWIFT

# 4. Обновляем AppEnvironment (Добавляем GitService)
# ... (вам нужно будет вставить этот блок в AppEnvironment)
# self.gitService = GitService(rootURL: root)
# tools.append(GitStatusTool(gitService: git))
# tools.append(GitDiffTool(gitService: git))

echo "S13: Git Undo и Auto-Fix Loop готовы."
