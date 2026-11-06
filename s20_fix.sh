#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Обновляем EditFileTool (Защита от пустых замен)
cat > Bosun/Services/Tools/Mutating/EditFileTool.swift <<'SWIFT'
import Foundation

struct EditFileTool: AgentTool {
    let sandbox: Sandbox
    
    var requiresApproval: Bool { true }
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "edit_file",
            description: "Заменяет конкретный фрагмент текста в файле. 'old_string' должен точно совпадать с текстом в файле.",
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
    
    func prepareApproval(arguments: String) async throws -> ApprovalRequest? {
        let args = try decodeArgs(Args.self, from: arguments)
        return ApprovalRequest(toolName: definition.name, path: args.path, oldContent: args.old_string, newContent: args.new_string)
    }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        
        // ЗАЩИТА 1: Нельзя менять пустоту на пустоту
        if args.old_string == args.new_string {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Ошибка: old_string и new_string идентичны. Ты не внес никаких изменений."])
        }
        if args.old_string.isEmpty {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Ошибка: old_string не может быть пустым."])
        }
        
        let url = try await sandbox.resolve(args.path)
        try await sandbox.validateExists(url)
        
        let originalContent = try String(contentsOf: url, encoding: .utf8)
        var content = originalContent
        
        var occurrences = content.components(separatedBy: args.old_string).count - 1
        
        // Фолбэк 1: Игнорируем пробелы
        if occurrences == 0 {
            let strippedOld = args.old_string.components(separatedBy: .whitespacesAndNewlines).joined()
            let lines = content.components(separatedBy: .newlines)
            let oldLines = args.old_string.components(separatedBy: .newlines)
            
            for i in 0...(lines.count - oldLines.count) {
                let slice = lines[i..<(i + oldLines.count)].joined()
                let strippedSlice = slice.components(separatedBy: .whitespacesAndNewlines).joined()
                
                if strippedSlice == strippedOld {
                    let newContent = Array(lines[..<i]) + [args.new_string] + Array(lines[(i + oldLines.count)...])
                    content = newContent.joined(separator: "\n")
                    occurrences = 1
                    break
                }
            }
        }
        
        if occurrences == 0 {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Строка old_string не найдена в файле. Попробуй скопировать текст точнее."])
        }
        if occurrences > 1 {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Строка old_string встречается \(occurrences) раз. Нужен более уникальный фрагмент."])
        }
        
        // ЗАЩИТА 2: Проверяем, что файл реально изменился
        if content == originalContent {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Ошибка: Замена не внесла изменений в файл. Возможно, ты заменил текст на точно такой же."])
        }
        
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Файл \(args.path) успешно изменен."
    }
}
SWIFT

# 2. Обновляем ChatView (Убираем тяжелый onChange для скролла)
cat > Bosun/Views/Chat/ChatView.swift <<'SWIFT'
import SwiftUI
import AppKit
import SwiftData

struct ChatView: View {
    @Bindable var vm: ChatViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(env.projectRoot?.lastPathComponent ?? "Проект не выбран").font(.headline)
                Spacer()
                Button { Task { try? await env.gitService?.undoAllChanges(); _ = await env.projectMap?.refreshTree(); await vm.loadTree(from: env.projectMap) } } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).help("Откатить все изменения")
                Button { isRefreshing = true; Task { _ = await env.projectMap?.refreshTree(); await vm.loadTree(from: env.projectMap); isRefreshing = false } } label: { if isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") } }
                    .buttonStyle(.borderless)
                Button { selectFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.messages) { msg in
                            if !msg.content.isEmpty { MessageBubble(message: msg).id(msg.id) }
                            if let calls = msg.toolCalls {
                                ForEach(calls) { call in
                                    if let res = vm.completedToolCalls.first(where: { $0.toolCallId == call.id }) {
                                        ToolCallCard(call: call, result: res)
                                    } else { ToolCallCard(call: call, result: nil) }
                                }
                            }
                        }
                        if !vm.streamingText.isEmpty { 
                            MessageBubble(message: ChatMessage(role: .assistant, content: vm.streamingText))
                                .id("stream") 
                        }
                        if let err = vm.error { Text(err).foregroundStyle(.red).font(.callout) }
                    }
                    .padding(16)
                }
                // ФИКС: Убираем onChange для streamingText, чтобы не было ошибки multiple updates
                // Вместо этого используем .onChange только для количества сообщений
                .onChange(of: vm.messages.count) { _, _ in 
                    if let last = vm.messages.last { 
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } 
                    } 
                }
            }
            
            Divider()
            if env.projectRoot == nil { Text("Выберите проект, чтобы агент мог использовать инструменты.").font(.caption).foregroundStyle(.orange).padding(.top, 8) }
            Composer(vm: vm, env: env)
        }
        .onAppear {
            env.modelContext = context
            if env.projectRoot != nil { 
                env.projectRoot = env.projectRoot 
                Task {
                    env.checkIfIndexed(context: context)
                    if !env.indexState.isReady && !env.indexState.isIndexing {
                        await env.startIndexing(context: context)
                    }
                }
            }
        }
        .sheet(isPresented: .init(get: { !vm.pendingApprovals.isEmpty }, set: { _ in })) {
            ApprovalSheet(requests: vm.pendingApprovals, onApprove: { allowSession in vm.resolveApproval(approved: true, allowSession: allowSession) }, onReject: { vm.resolveApproval(approved: false) })
        }
    }
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            env.projectRoot = url
            Task { await vm.loadTree(from: env.projectMap) }
        }
    }
}
SWIFT

echo "S20: Защита от пустых правок и фикс UI готовы."
