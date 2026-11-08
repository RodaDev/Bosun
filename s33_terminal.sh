#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

mkdir -p Bosun/Services/Tools/Build

# 1. Создаем RunCommandTool
cat > Bosun/Services/Tools/Build/RunCommandTool.swift <<'SWIFT'
import Foundation

struct RunCommandTool: AgentTool {
    let sandbox: Sandbox
    
    var requiresApproval: Bool { true }
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "run_command",
            description: "Выполняет команду в терминале (например, 'swift test', 'npm run build'). Требует подтверждения.",
            parameters: [
                "executable": ToolParameter(description: "Имя программы (например, 'swift', 'npm', 'git')"),
                "arguments": ToolParameter(type: "array", description: "Массив строк-аргументов (например, [\"test\", \"--verbose\"])")
            ]
        )
    }
    
    struct Args: Decodable {
        let executable: String
        let arguments: [String]
    }
    
    // Показываем команду в окне подтверждения
    func prepareApproval(arguments: String) async throws -> ApprovalRequest? {
        let args = try decodeArgs(Args.self, from: arguments)
        let cmdString = "\(args.executable) \(args.arguments.joined(separator: " "))"
        return ApprovalRequest(
            toolName: definition.name,
            path: "Запуск в терминале",
            oldContent: nil,
            newContent: cmdString
        )
    }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        
        // Проверяем, что executable не содержит путей (защита от /bin/rm -rf /)
        guard !args.executable.contains("/") else {
            throw NSError(domain: "Command", code: 0, userInfo: [NSLocalizedDescriptionKey: "Запрещено указывать полный путь к исполняемому файлу. Используй имя программы (например, 'swift')."])
        }
        
        let root = await sandbox.rootURL
        
        let process = Process()
        // Ищем программу в PATH
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [args.executable] + args.arguments
        process.currentDirectoryURL = root
        
        // Подхватываем переменные окружения (чтобы работал brew, node, python)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
        } catch {
            throw NSError(domain: "Command", code: 0, userInfo: [NSLocalizedDescriptionKey: "Не удалось запустить '\(args.executable)': \(error.localizedDescription)"])
        }
        
        // Таймаут 120 секунд
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            if process.isRunning {
                process.terminate()
            }
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutTask.cancel()
        
        let output = String(data: data, encoding: .utf8) ?? ""
        
        // Ограничиваем вывод (чтобы не забивать контекст)
        let lines = output.components(separatedBy: .newlines)
        let truncated = lines.suffix(100).joined(separator: "\n")
        
        var result = "Код выхода: \(process.terminationStatus)\n"
        if process.terminationReason == .uncaughtSignal {
            result += "Процесс был принудительно завершен по таймауту (120 сек).\n"
        }
        
        if process.terminationStatus == 0 {
            result += "Команда выполнена успешно.\n"
        } else {
            result += "Команда завершилась с ошибкой.\n"
        }
        
        result += "\nЛог (последние 100 строк):\n\(truncated)"
        return result
    }
}
SWIFT

# 2. Обновляем AppEnvironment (Регистрация инструмента)
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
                    ListDirTool(sandbox: box), ReadFileTool(sandbox: box, index: idx),
                    ReadSymbolTool(sandbox: box, index: idx), SearchTool(sandbox: box),
                    FindSymbolTool(index: idx), ListSymbolsTool(sandbox: box, index: idx),
                    WriteFileTool(sandbox: box), EditFileTool(sandbox: box),
                    RunXcodebuildTool(runner: runner), RunCommandTool(sandbox: box), // <-- НОВЫЙ ИНСТРУМЕНТ
                    GitStatusTool(gitService: git), GitDiffTool(gitService: git)
                ]
                if let ctx = modelContext {
                    tools.append(SemanticSearchTool(client: openRouter, context: ctx))
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

# 3. Добавляем правило в PromptBuilder (Как использовать run_command)
cat > Bosun/Services/Agent/PromptBuilder.swift <<'SWIFT'
import Foundation

struct PromptBuilder {
    static func buildSystemPrompt(tree: String?, projectRules: String?) -> String {
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
        
        prompt += """
        ПРАВИЛА:
        1. Твоя единственная цель — выполнить задачу из ПОСЛЕДНЕГО сообщения пользователя.
        2. Сначала прочитай нужные файлы (максимум 3-4 файла), чтобы понять код.
        3. Как только ты понял проблему — СРАЗУ ИСПОЛЬЗУЙ `edit_file` для правок.
        4. НЕ ЧИТАЙ файлы повторно, если ты уже делал это в этой сессии.
        5. Отвечай кратко. Если закончил — напиши текстовый ответ и остановись.
        
        ИНСТРУМЕНТЫ ПОИСКА:
        - Если пользователь спрашивает "Где находится...", "Где обрабатывается...", "Как работает...", 
          ВСЕГДА используй `semantic_search`. 
        - Обычный `search` используй только тогда, когда тебе нужно найти конкретное имя переменной.
        
        ТЕРМИНАЛ:
        - Ты можешь запускать команды через `run_command` (например, `swift test`, `npm run build`). 
        - Используй его только когда это необходимо (например, для запуска тестов).
        
        КРИТИЧЕСКИЕ ПРАВИЛА ПРИ РЕДАКТИРОВАНИИ:
        1. Если ты удаляешь структуру, класс или функцию, ты ОБЯЗАН удалить его ЦЕЛИКОМ (от `struct` до последней `}`). 
           НИКОГДА не оставляй внутренности структуры висеть в воздухе, закомментировав только сигнатуру!
        2. ЧТОБЫ УДАЛИТЬ КОД: передай в `edit_file` параметр `new_string` как пустую строку `""`. 
           НЕ ПЫТАЙСЯ закомментировать код! Просто удали его.
        3. Если ты меняешь сигнатуру метода, ты ОБЯЗАН обновить все места, где этот метод вызывается.
        """
        
        return prompt
    }
}
SWIFT

echo "S33: Настоящий Терминал готов."
