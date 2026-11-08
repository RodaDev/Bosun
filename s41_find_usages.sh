#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Создаем инструмент FindUsagesTool
cat > Bosun/Services/Tools/ReadOnly/FindUsagesTool.swift <<'SWIFT'
import Foundation

struct FindUsagesTool: AgentTool {
    let sandbox: Sandbox
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "find_usages",
            description: "Находит все места в проекте, где используется указанный метод, переменная или класс. Используй перед рефакторингом (переименованием), чтобы не сломать вызовы.",
            parameters: [
                "symbol": ToolParameter(description: "Имя символа (например, 'apply', 'DocumentViewModel', 'saveDocument')")
            ]
        )
    }
    
    struct Args: Decodable { let symbol: String }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let root = await sandbox.rootURL
        
        // Экранируем спецсимволы для регулярки
        let escapedSymbol = NSRegularExpression.escapedPattern(for: args.symbol)
        // Ищем слово целиком (чтобы 'apply' не находил 'applySomething')
        // Игнорируем комментарии (строки, начинающиеся с //)
        let pattern = "(?<!//.*)\\b\(escapedSymbol)\\b"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return "Ошибка создания регулярного выражения."
        }
        
        var results: [String] = []
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { return "Ошибка доступа к файлам." }
        
        for case let fileURL as URL in enumerator {
            if ExcludedPaths.names.contains(where: { fileURL.path.contains("/\($0)/") }) { continue }
            guard fileURL.pathExtension == "swift" else { continue }
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: .newlines)
            let relPath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    // Пропускаем строку, если это само объявление (func apply, let apply)
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("func \(args.symbol)") ||
                       trimmed.hasPrefix("let \(args.symbol)") ||
                       trimmed.hasPrefix("var \(args.symbol)") ||
                       trimmed.hasPrefix("struct \(args.symbol)") ||
                       trimmed.hasPrefix("class \(args.symbol)") {
                        continue
                    }
                    
                    let cleanLine = line.trimmingCharacters(in: .whitespaces)
                    results.append("\(relPath):\(index + 1): \(cleanLine)")
                }
            }
        }
        
        if results.isEmpty {
            return "Использований символа '\(args.symbol)' не найдено."
        }
        
        return "Найдено \(results.count) использований:\n" + results.prefix(50).joined(separator: "\n") + (results.count > 50 ? "\n...[УСЕЧЕНО]" : "")
    }
}
SWIFT

# 2. Регистрируем в AppEnvironment
cat > Bosun/App/AppEnvironment.swift <<'SWIFT'
import Foundation
import Observation
import SwiftData

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
    var gitService: GitService?
    var indexerService: IndexerService?
    
    var modelContext: ModelContext?
    var indexState = IndexState()
    var projectRules: String?
    var projectMemory: String?
    
    var projectRoot: URL? {
        didSet {
            if let root = projectRoot {
                let box = Sandbox(rootURL: root)
                let idx = SymbolIndex(rootURL: root)
                let map = ProjectMap(rootURL: root)
                let runner = XcodeBuildRunner(rootURL: root)
                let git = GitService(rootURL: root)
                
                self.sandbox = box; self.symbolIndex = idx; self.projectMap = map; self.gitService = git
                self.indexerService = IndexerService(sandbox: box, client: openRouter, gitService: git)
                
                let rulesURL = root.appendingPathComponent(".bosunrules")
                if let rulesText = try? String(contentsOf: rulesURL, encoding: .utf8) {
                    self.projectRules = rulesText
                } else {
                    self.projectRules = nil
                }
                
                var tools: [AgentTool] = [
                    ListDirTool(sandbox: box), 
                    ReadFileTool(sandbox: box, index: idx),
                    ReadSymbolTool(sandbox: box, index: idx), 
                    SearchTool(sandbox: box),
                    FindSymbolTool(index: idx), 
                    FindUsagesTool(sandbox: box), // <-- НОВЫЙ ИНСТРУМЕНТ
                    ListSymbolsTool(sandbox: box, index: idx),
                    WriteFileTool(sandbox: box), 
                    EditFileTool(sandbox: box),
                    RunXcodebuildTool(runner: runner), 
                    RunCommandTool(sandbox: box),
                    GitStatusTool(gitService: git), 
                    GitDiffTool(gitService: git)
                ]
                
                if let ctx = modelContext {
                    tools.append(SemanticSearchTool(client: openRouter, context: ctx))
                    tools.append(UpdateMemoryTool(projectRoot: root, context: ctx))
                    
                    let path = root.path
                    let descriptor = FetchDescriptor<ProjectMemory>(
                        predicate: #Predicate { $0.projectPath == path },
                        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
                    )
                    if let memories = try? ctx.fetch(descriptor), !memories.isEmpty {
                        let facts = memories.map { "- \($0.fact)" }.joined(separator: "\n")
                        self.projectMemory = facts
                    } else {
                        self.projectMemory = nil
                    }
                }
                
                self.toolRuntime = ToolRuntime(registry: ToolRegistry(tools: tools))
                settings.projectRootPath = root.path
                self.indexState = IndexState()
                
                Task { try? await idx.rebuild() }
            } else {
                sandbox = nil; symbolIndex = nil; projectMap = nil; toolRuntime = nil
                gitService = nil; indexerService = nil; settings.projectRootPath = nil
                self.indexState = IndexState()
                self.projectRules = nil
                self.projectMemory = nil
            }
        }
    }

    init() {
        let settings = SettingsStore()
        let keychain = KeychainStore()
        let transport = URLSessionTransport()
        let client = OpenRouterClient(transport: transport, keychain: keychain)

        self.settings = settings; self.keychain = keychain; self.openRouter = client
        self.chatVM = ChatViewModel(settings: settings, keychain: keychain, client: client)
        self.modelPickerVM = ModelPickerViewModel(client: client)
        self.settingsVM = SettingsViewModel(settings: settings, keychain: keychain)

        if self.keychain.loadAPIKey() == nil { self.settings.hasAPIKey = false }
        if let path = settings.projectRootPath { self.projectRoot = URL(fileURLWithPath: path) }
    }
    
    func startIndexing(context: ModelContext) async {
        self.modelContext = context
        guard let indexer = indexerService else { return }
        indexState.status = .indexing(progress: "Подготовка...")
        do {
            try await indexer.indexProject(context: context) { msg in
                Task { @MainActor in self.indexState.status = .indexing(progress: msg) }
            }
            self.indexState.status = .indexed(date: Date())
        } catch {
            self.indexState.status = .error(error.localizedDescription)
        }
    }
    
    func checkIfIndexed(context: ModelContext) {
        let descriptor = FetchDescriptor<CodeChunk>()
        if let count = try? context.fetchCount(descriptor), count > 0 {
            self.indexState.status = .indexed(date: Date())
        } else {
            self.indexState.status = .notIndexed
        }
    }
}
SWIFT

# 3. Обновляем PromptBuilder (Добавляем правило про рефакторинг)
cat > Bosun/Services/Agent/PromptBuilder.swift <<'SWIFT'
import Foundation

struct PromptBuilder {
    static func buildSystemPrompt(tree: String?, projectRules: String?, projectMemory: String?) -> String {
        var prompt = """
        Ты — Bosun, полезный ИИ-ассистент для разработки на macOS.
        Ты работаешь внутри проекта пользователя.
        
        """
        
        if let tree = tree {
            prompt += "Структура проекта:\n\(tree)\n\n"
        }
        
        if let rules = projectRules, !rules.isEmpty {
            prompt += """
            КРИТИЧЕСКИ ВАЖНЫЕ ПРАВИЛА ЭТОГО ПРОЕКТА (СОБЛЮДАЙ ИХ СТРОГО):
            \(rules)
            ========================================================
            
            """
        }
        
        if let memory = projectMemory, !memory.isEmpty {
            prompt += """
            ПАМЯТЬ ПРОЕКТА (ИЗ ПРЕДЫДУЩИХ СЕССИЙ):
            \(memory)
            ========================================================
            
            """
        }
        
        prompt += """
        ПРАВИЛА:
        1. Твоя единственная цель — выполнить задачу из ПОСЛЕДНЕГО сообщения пользователя.
        2. Если ты меняешь код, ты ОБЯЗАН написать тест. 
        3. Если ты делаешь РЕФАКТОРИНГ (переименование метода, класса или переменной), ты ОБЯЗАН сначала использовать `find_usages`, чтобы найти все места вызова. Иначе ты сломаешь сборку.
        4. Если ты не знаешь, в каком файле находится View, используй `search` по имени структуры.
        5. НЕ ЧИТАЙ файлы повторно. Отвечай кратко. Если закончил — напиши текстовый ответ.
        
        АРХИТЕКТУРНЫЕ ОГРАНИЧЕНИЯ:
        ViewModel не должен импортировать SwiftUI. Если нужен `Color`, создай `enum` во ViewModel, а extension с цветом сделай во View.
        
        КРИТИЧЕСКИЕ ПРАВИЛА ПРИ РЕДАКТИРОВАНИИ:
        1. Если удаляешь структуру — удаляй ЦЕЛИКОМ (от `struct` до последней `}`). 
        2. ЧТОБЫ УДАЛИТЬ КОД: передай в `edit_file` параметр `new_string` как пустую строку `""`. 
        3. Если меняешь сигнатуру — обнови все места вызова.
        
        ИНСТРУМЕНТ ПАМЯТИ:
        Если ты узнаешь важный архитектурный факт о проекте, используй `update_memory`.
        """
        
        return prompt
    }
}
SWIFT

echo "S41: Find Usages готов."
