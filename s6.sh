#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Обновляем ProjectMap (добавляем кэш)
cat > Bosun/Services/Index/ProjectMap.swift <<'SWIFT'
import Foundation

actor ProjectMap {
    private let rootURL: URL
    private var cachedTree: String?
    
    init(rootURL: URL) {
        self.rootURL = rootURL
    }
    
    /// Возвращает текстовое дерево (из кэша, если есть)
    func getTree() async -> String {
        if let cached = cachedTree { return cached }
        let tree = await buildTree()
        cachedTree = tree
        return tree
    }
    
    /// Принудительно пересобирает дерево
    func refreshTree() async -> String {
        let tree = await buildTree()
        cachedTree = tree
        return tree
    }
    
    private func buildTree() async -> String {
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
            if name.hasPrefix(".") { continue }
            
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let children = await getChildren(of: fileURL)
                nodes.append(Node(url: fileURL, isDirectory: true, children: children))
            } else {
                nodes.append(Node(url: fileURL, isDirectory: false, children: []))
            }
        }
        
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

# 2. Обновляем ProjectTreeView (Кнопка обновления карты)
cat > Bosun/Views/Project/ProjectTreeView.swift <<'SWIFT'
import SwiftUI
import AppKit

struct ProjectTreeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isRefreshing = false

    var body: some View {
        VStack {
            if let root = env.projectRoot {
                List {
                    Section {
                        Text(root.lastPathComponent)
                            .font(.headline)
                    }
                    
                    Section("Действия") {
                        Button {
                            isRefreshing = true
                            Task {
                                if let map = env.projectMap {
                                    _ = await map.refreshTree()
                                }
                                if let idx = env.symbolIndex {
                                    try? await idx.rebuild()
                                }
                                isRefreshing = false
                            }
                        } label: {
                            HStack {
                                if isRefreshing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text("Обновить карту проекта")
                            }
                        }
                        .disabled(isRefreshing)
                        
                        Button("Сменить проект") { selectFolder() }
                    }
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

# 3. Обновляем AgentCore (Используем кэш карты)
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
                let tree = await projectMap?.getTree()
                let systemPrompt = PromptBuilder.buildSystemPrompt(tree: tree)
                
                var messages: [ChatMessage] = []
                messages.append(ChatMessage(role: .system, content: systemPrompt))
                
                // Берем только последние 20 сообщений, чтобы не раздувать контекст
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

# 4. Обновляем BosunApp (Привязка Settings)
cat > Bosun/App/BosunApp.swift <<'SWIFT'
import SwiftUI

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
            .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .commands { CommandGroup(replacing: .newItem) {} }

        Settings {
            SettingsView().environment(env)
        }
    }
}
SWIFT

echo "S6: Полировка завершена."
