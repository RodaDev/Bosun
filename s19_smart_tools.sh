#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

mkdir -p Bosun/Services/Tools/ReadOnly

# 1. Обновляем ReadFileTool (Скелет файла)
cat > Bosun/Services/Tools/ReadOnly/ReadFileTool.swift <<'SWIFT'
import Foundation

struct ReadFileTool: AgentTool {
    let sandbox: Sandbox
    let index: SymbolIndex
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "read_file",
            description: "Читает файл. Если start_line не указан, возвращает скелет (структуру классов и методов). Используй start_line, чтобы прочитать конкретный код.",
            parameters: [
                "path": ToolParameter(description: "Относительный путь к файлу"),
                "start_line": ToolParameter(type: "integer", description: "С какой строки начать (опционально)")
            ]
        )
    }
    
    struct Args: Decodable {
        let path: String
        let start_line: Int?
    }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let url = try await sandbox.resolve(args.path)
        try await sandbox.validateExists(url)
        
        // УМНОЕ ЧТЕНИЕ: Если start_line нет, отдаем скелет
        if args.start_line == nil {
            let symbols = await index.listForFile(url)
            if !symbols.isEmpty {
                var outline = "Файл \(args.path):\n"
                for sym in symbols {
                    outline += "\(sym.line): \(sym.kind) \(sym.name)\n"
                }
                outline += "\n[Система: Это скелет файла. Используй start_line: <номер>, чтобы прочитать код, или инструмент read_symbol, чтобы прочитать функцию целиком.]"
                return outline
            }
        }
        
        // Обычное чтение (если запросили конкретные строки или скелет пуст)
        let data = try Data(contentsOf: url)
        if data.count > 256 * 1024 {
            let string = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
            return string + "\n\n...[ФАЙЛ УСЕЧЕН: превышен лимит в 256 КБ]..."
        }
        
        guard let content = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Tool", code: 0, userInfo: [NSLocalizedDescriptionKey: "Файл не в кодировке UTF-8"])
        }
        
        let lines = content.components(separatedBy: .newlines)
        let start = max(0, (args.start_line ?? 1) - 1)
        let totalLines = lines.count
        
        if start >= totalLines { return "(начало за пределами файла)" }
        
        let end = min(totalLines, start + 100)
        let slice = lines[start..<end]
        
        var result = slice.enumerated().map { "\(start + $0.offset + 1): \($0.element)" }.joined(separator: "\n")
        if end < totalLines {
            result += "\n...[УСЕЧЕНО: показано 100 строк из \(totalLines). Для продолжения используй start_line: \(end + 1)]"
        }
        
        return result
    }
}
SWIFT

# 2. Создаем ReadSymbolTool (Точечное чтение функции)
cat > Bosun/Services/Tools/ReadOnly/ReadSymbolTool.swift <<'SWIFT'
import Foundation

struct ReadSymbolTool: AgentTool {
    let sandbox: Sandbox
    let index: SymbolIndex
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "read_symbol",
            description: "Читает код конкретной функции, класса или структуры по имени.",
            parameters: [
                "name": ToolParameter(description: "Имя символа (например, 'apply' или 'DocumentCropView')"),
                "path": ToolParameter(description: "Опционально: путь к файлу, если символ встречается в нескольких местах")
            ]
        )
    }
    
    struct Args: Decodable {
        let name: String
        let path: String?
    }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        
        var symbols = await index.find(name: args.name)
        if let path = args.path {
            let url = try await sandbox.resolve(path)
            symbols = symbols.filter { $0.fileURL.path == url.path }
        }
        
        guard let sym = symbols.first else {
            return "Символ '\(args.name)' не найден."
        }
        
        let url = sym.fileURL
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "Не удалось прочитать файл \(url.lastPathComponent)"
        }
        
        let lines = content.components(separatedBy: .newlines)
        let start = max(0, sym.line - 1)
        
        // Простой алгоритм поиска закрывающей скобки
        var braceCount = 0
        var endLine = start
        var foundOpening = false
        
        for i in start..<lines.count {
            let line = lines[i]
            for char in line {
                if char == "{" { braceCount += 1; foundOpening = true }
                else if char == "}" { braceCount -= 1 }
            }
            if foundOpening && braceCount == 0 {
                endLine = i
                break
            }
            // Если это просто var/let без скобок
            if i == start && !foundOpening && i < lines.count - 1 {
                endLine = start // Возьмем только одну строку для объявления
            }
        }
        
        let slice = lines[start...min(endLine, lines.count - 1)]
        let result = slice.enumerated().map { "\(start + $0.offset + 1): \($0.element)" }.joined(separator: "\n")
        
        return "Код символа '\(sym.name)' в \(url.lastPathComponent) (\(start+1)-\(endLine+1)):\n\(result)"
    }
}
SWIFT

# 3. Обновляем EditFileTool (Фолбэк с подсказкой)
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
        let url = try await sandbox.resolve(args.path)
        try await sandbox.validateExists(url)
        
        var content = try String(contentsOf: url, encoding: .utf8)
        let originalContent = content
        
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
        
        // Фолбэк 2: Если не нашли, подсказываем ближайший блок
        if occurrences == 0 {
            let lines = content.components(separatedBy: .newlines)
            let oldLines = args.old_string.components(separatedBy: .newlines)
            
            var bestMatchIndex = 0
            var bestMatchScore = 0.0
            
            if lines.count >= oldLines.count {
                for i in 0...(lines.count - oldLines.count) {
                    let slice = lines[i..<(i + oldLines.count)]
                    var matches = 0
                    for (l1, l2) in zip(slice, oldLines) {
                        if l1.trimmingCharacters(in: .whitespaces) == l2.trimmingCharacters(in: .whitespaces) {
                            matches += 1
                        }
                    }
                    let score = Double(matches) / Double(oldLines.count)
                    if score > bestMatchScore {
                        bestMatchScore = score
                        bestMatchIndex = i
                    }
                }
            }
            
            if bestMatchScore > 0.5 {
                let slice = lines[bestMatchIndex..<(bestMatchIndex + oldLines.count)].joined(separator: "\n")
                throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Строка old_string не найдена. Возможно, ты имел в виду этот блок (строки \(bestMatchIndex+1)-\(bestMatchIndex+oldLines.count)):\n---\n\(slice)\n---\nПожалуйста, скопируй этот текст ТОЧНО в old_string и попробуй снова."])
            }
            
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Строка old_string не найдена в файле. Попробуй использовать write_file для полной перезаписи файла."])
        }
        
        if occurrences > 1 {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Строка old_string встречается \(occurrences) раз. Нужен более уникальный фрагмент."])
        }
        
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Файл \(args.path) успешно изменен."
    }
}
SWIFT

# 4. Обновляем AppEnvironment (Регистрация новых инструментов)
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
                
                var tools: [AgentTool] = [
                    ListDirTool(sandbox: box), 
                    ReadFileTool(sandbox: box, index: idx), // <-- Обновлено
                    ReadSymbolTool(sandbox: box, index: idx), // <-- Новое
                    SearchTool(sandbox: box),
                    FindSymbolTool(index: idx), 
                    ListSymbolsTool(sandbox: box, index: idx),
                    WriteFileTool(sandbox: box), 
                    EditFileTool(sandbox: box),
                    RunXcodebuildTool(runner: runner), 
                    GitStatusTool(gitService: git), 
                    GitDiffTool(gitService: git)
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

echo "S19: Умное чтение и редактирование готовы."
