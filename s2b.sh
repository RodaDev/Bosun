#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

mkdir -p Bosun/Services/Tools/ReadOnly
mkdir -p Bosun/Services/Index

# 1. AgentTool Protocol
cat > Bosun/Services/Tools/AgentTool.swift <<'SWIFT'
import Foundation

/// Схема параметров в формате JSON Schema (совместимо с OpenRouter/OpenAI)
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
    func execute(arguments: String) async throws -> String
}

// Вспомогательная функция для парсинга аргументов
extension AgentTool {
    func decodeArgs<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "Tool", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF8 in arguments"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
SWIFT

# 2. ToolRegistry
cat > Bosun/Services/Tools/ToolRegistry.swift <<'SWIFT'
import Foundation

final class ToolRegistry: Sendable {
    private let tools: [String: AgentTool]
    
    init(tools: [AgentTool]) {
        var dict: [String: AgentTool] = [:]
        for tool in tools {
            dict[tool.definition.name] = tool
        }
        self.tools = dict
    }
    
    func get(_ name: String) -> AgentTool? {
        tools[name]
    }
    
    /// Возвращает массив словарей для поля `tools` в запросе OpenRouter
    var openRouterSchema: [[String: Any]] {
        tools.values.map { tool in
            let def = tool.definition
            var props: [String: Any] = [:]
            var required: [String] = []
            
            for (key, param) in def.parameters {
                var p: [String: Any] = ["type": param.type, "description": param.description]
                if let enumVals = param.enum { p["enum"] = enumVals }
                props[key] = p
                required.append(key) // Для простоты все параметры обязательны
            }
            
            let parametersSchema: [String: Any] = [
                "type": "object",
                "properties": props,
                "required": required
            ]
            
            return [
                "type": "function",
                "function": [
                    "name": def.name,
                    "description": def.description,
                    "parameters": parametersSchema
                ]
            ]
        }
    }
}
SWIFT

# 3. ToolRuntime
cat > Bosun/Services/Tools/ToolRuntime.swift <<'SWIFT'
import Foundation

actor ToolRuntime {
    private let registry: ToolRegistry
    
    init(registry: ToolRegistry) {
        self.registry = registry
    }
    
    var openRouterTools: [[String: Any]] {
        registry.openRouterSchema
    }
    
    func execute(_ call: ToolCall) async -> ToolResult {
        guard let tool = registry.get(call.function.name) else {
            return ToolResult.error(call.id, "Инструмент '\(call.function.name)' не найден")
        }
        
        do {
            let output = try await tool.execute(arguments: call.function.arguments)
            return ToolResult(toolCallId: call.id, content: output, isError: false)
        } catch {
            return ToolResult.error(call.id, error.localizedDescription)
        }
    }
}
SWIFT

# 4. SymbolParser
cat > Bosun/Services/Index/SymbolParser.swift <<'SWIFT'
import Foundation

struct SymbolParser {
    /// Очень простой regex-парсер верхнеуровневых типов и функций
    static func parse(fileURL: URL, content: String) -> [Symbol] {
        var symbols: [Symbol] = []
        let lines = content.components(separatedBy: .newlines)
        
        // Ищем struct, class, enum, protocol, func, var, let на верхнем уровне (без отступов)
        let pattern = #"^(?:public\s+|private\s+|internal\s+|fileprivate\s+)?(struct|class|enum|protocol|extension|func|var|let|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        
        for (index, line) in lines.enumerated() {
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex.firstMatch(in: line, range: nsRange) {
                // Извлекаем тип и имя
                if let kindRange = Range(match.range(at: 1), in: line),
                   let nameRange = Range(match.range(at: 2), in: line) {
                    let kind = String(line[kindRange])
                    let name = String(line[nameRange])
                    symbols.append(Symbol(
                        name: name,
                        kind: kind,
                        fileURL: fileURL,
                        line: index + 1
                    ))
                }
            }
        }
        return symbols
    }
}
SWIFT

# 5. SymbolIndex
cat > Bosun/Services/Index/SymbolIndex.swift <<'SWIFT'
import Foundation

actor SymbolIndex {
    private var symbolsByFile: [URL: [Symbol]] = [:]
    private let rootURL: URL
    
    init(rootURL: URL) {
        self.rootURL = rootURL
    }
    
    func rebuild() async throws {
        symbolsByFile.removeAll()
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: nil) else { return }
        
        for case let fileURL as URL in enumerator {
            // Пропускаем исключенные папки
            if ExcludedPaths.names.contains(where: { fileURL.path.contains("/\($0)/") }) {
                enumerator.skipDescendants()
                continue
            }
            guard fileURL.pathExtension == "swift" else { continue }
            
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                let symbols = SymbolParser.parse(fileURL: fileURL, content: content)
                if !symbols.isEmpty {
                    symbolsByFile[fileURL] = symbols
                }
            }
        }
    }
    
    func find(name: String) -> [Symbol] {
        symbolsByFile.values.flatMap { $0 }.filter { $0.name.localizedCaseInsensitiveContains(name) }
    }
    
    func listAll() -> [Symbol] {
        symbolsByFile.values.flatMap { $0 }
    }
    
    func listForFile(_ url: URL) -> [Symbol] {
        symbolsByFile[url] ?? []
    }
}
SWIFT

# --- Tools ---

# ListDirTool
cat > Bosun/Services/Tools/ReadOnly/ListDirTool.swift <<'SWIFT'
import Foundation

struct ListDirTool: AgentTool {
    let sandbox: Sandbox
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "list_dir",
            description: "Показывает список файлов и папок по указанному пути (относительно корня проекта).",
            parameters: ["path": ToolParameter(description: "Относительный путь к папке (например, 'Sources' или '.')")]
        )
    }
    
    struct Args: Decodable { let path: String }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let url = try await sandbox.resolve(args.path)
        try await sandbox.validateExists(url)
        
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        
        let result = contents.map { fileURL -> String in
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = fileURL.lastPathComponent
            return isDir ? "\(name)/" : name
        }.sorted().joined(separator: "\n")
        
        return result.isEmpty ? "(пустая папка)" : result
    }
}
SWIFT

# ReadFileTool
cat > Bosun/Services/Tools/ReadOnly/ReadFileTool.swift <<'SWIFT'
import Foundation

struct ReadFileTool: AgentTool {
    let sandbox: Sandbox
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "read_file",
            description: "Читает содержимое файла. Максимум 256 КБ или 4000 строк. Используйте start_line для чтения больших файлов по частям.",
            parameters: [
                "path": ToolParameter(description: "Относительный путь к файлу"),
                "start_line": ToolParameter(type: "integer", description: "С какой строки начать (опционально, по умолчанию 1)")
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
        
        let data = try Data(contentsOf: url)
        if data.count > 256 * 1024 {
            let string = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
            return string + "\n\n...[ФАЙЛ УСЕЧЕН: превышен лимит в 256 КБ. Используйте search или смещение]..."
        }
        
        guard let content = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Tool", code: 0, userInfo: [NSLocalizedDescriptionKey: "Файл не в кодировке UTF-8"])
        }
        
        let lines = content.components(separatedBy: .newlines)
        let start = max(0, (args.start_line ?? 1) - 1)
        
        if start >= lines.count { return "(начало за пределами файла)" }
        
        let end = min(lines.count, start + 4000)
        let slice = lines[start..<end]
        
        var result = slice.enumerated().map { "\(start + $0.offset + 1): \($0.element)" }.joined(separator: "\n")
        if end < lines.count {
            result += "\n...[УСЕЧЕНО: показано \(slice.count) строк из \(lines.count). Для продолжения используйте start_line: \(end + 1)]"
        }
        
        return result
    }
}
SWIFT

# SearchTool
cat > Bosun/Services/Tools/ReadOnly/SearchTool.swift <<'SWIFT'
import Foundation

struct SearchTool: AgentTool {
    let sandbox: Sandbox
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "search",
            description: "Ищет подстроку или регулярное выражение во всех файлах проекта (максимум 200 результатов).",
            parameters: ["query": ToolParameter(description: "Текст или Regex для поиска")]
        )
    }
    
    struct Args: Decodable { let query: String }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let root = await sandbox.rootURL
        let regex = try? NSRegularExpression(pattern: args.query, options: .caseInsensitive)
        
        var results: [String] = []
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return "Ошибка доступа" }
        
        for case let fileURL as URL in enumerator {
            if ExcludedPaths.names.contains(where: { fileURL.path.contains("/\($0)/") }) {
                enumerator.skipDescendants()
                continue
            }
            guard fileURL.pathExtension != "png", fileURL.pathExtension != "jpg" else { continue }
            
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 1024 * 1024 { continue } // > 1MB пропускаем
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: .newlines)
            
            for (idx, line) in lines.enumerated() {
                var match = false
                if let rx = regex {
                    match = rx.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) != nil
                } else {
                    match = line.localizedCaseInsensitiveContains(args.query)
                }
                
                if match {
                    let relPath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
                    results.append("\(relPath):\(idx + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    if results.count >= 200 {
                        results.append("...[УСЕЧЕНО: найдено больше 200 совпадений]...")
                        return results.joined(separator: "\n")
                    }
                }
            }
        }
        
        return results.isEmpty ? "Ничего не найдено" : results.joined(separator: "\n")
    }
}
SWIFT

# FindSymbolTool
cat > Bosun/Services/Tools/ReadOnly/FindSymbolTool.swift <<'SWIFT'
import Foundation

struct FindSymbolTool: AgentTool {
    let index: SymbolIndex
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "find_symbol",
            description: "Ищет объявления классов, структур, функций в проекте по имени.",
            parameters: ["name": ToolParameter(description: "Имя символа (или его часть)")]
        )
    }
    
    struct Args: Decodable { let name: String }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let symbols = await index.find(name: args.name)
        
        if symbols.isEmpty { return "Символы не найдены" }
        
        return symbols.map {
            "\($0.fileURL.lastPathComponent):\($0.line): \($0.kind) \($0.name)"
        }.joined(separator: "\n")
    }
}
SWIFT

# ListSymbolsTool
cat > Bosun/Services/Tools/ReadOnly/ListSymbolsTool.swift <<'SWIFT'
import Foundation

struct ListSymbolsTool: AgentTool {
    let sandbox: Sandbox
    let index: SymbolIndex
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "list_symbols",
            description: "Показывает все объявления (классы, функции и т.д.) в конкретном файле.",
            parameters: ["path": ToolParameter(description: "Путь к файлу")]
        )
    }
    
    struct Args: Decodable { let path: String }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let url = try await sandbox.resolve(args.path)
        
        let symbols = await index.listForFile(url)
        if symbols.isEmpty { return "В файле не найдено символов (или файл не проиндексирован)" }
        
        return symbols.map { "\($0.line): \($0.kind) \($0.name)" }.joined(separator: "\n")
    }
}
SWIFT

# Обновляем AppEnvironment
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
                    ListSymbolsTool(sandbox: box, index: idx)
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

        if let path = settings.projectRootPath {
            self.projectRoot = URL(fileURLWithPath: path)
        }
    }
}
SWIFT

# Тесты для инструментов
cat > BosunTests/ToolsTests.swift <<'SWIFT'
import XCTest
@testable import Bosun

final class ToolsTests: XCTestCase {
    var tempRoot: URL!
    var sandbox: Sandbox!
    var index: SymbolIndex!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        sandbox = Sandbox(rootURL: tempRoot)
        index = SymbolIndex(rootURL: tempRoot)
        
        // Создаем тестовые файлы
        let file1 = tempRoot.appendingPathComponent("App.swift")
        try "struct MyApp {\n    func run() {}\n}\n".write(to: file1, atomically: true, encoding: .utf8)
        
        let file2 = tempRoot.appendingPathComponent("Utils.swift")
        try "class Helper {\n    let x = 1\n}\n".write(to: file2, atomically: true, encoding: .utf8)
        
        let subDir = tempRoot.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "func test() {}".write(to: subDir.appendingPathComponent("Test.swift"), atomically: true, encoding: .utf8)
    }
    
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }
    
    func testListDir() async throws {
        let tool = ListDirTool(sandbox: sandbox)
        let result = try await tool.execute(arguments: #"{"path": "."}"#)
        XCTAssertTrue(result.contains("App.swift"))
        XCTAssertTrue(result.contains("Sub/"))
    }
    
    func testReadFile() async throws {
        let tool = ReadFileTool(sandbox: sandbox)
        let result = try await tool.execute(arguments: #"{"path": "App.swift"}"#)
        XCTAssertTrue(result.contains("1: struct MyApp"))
        XCTAssertTrue(result.contains("2:     func run()"))
    }
    
    func testSearch() async throws {
        let tool = SearchTool(sandbox: sandbox)
        let result = try await tool.execute(arguments: #"{"query": "MyApp"}"#)
        XCTAssertTrue(result.contains("App.swift:1"))
    }
    
    func testSymbolIndexAndFind() async throws {
        try await index.rebuild()
        
        let tool = FindSymbolTool(index: index)
        let result = try await tool.execute(arguments: #"{"name": "MyApp"}"#)
        XCTAssertTrue(result.contains("struct MyApp"))
    }
    
    func testListSymbols() async throws {
        try await index.rebuild()
        
        let tool = ListSymbolsTool(sandbox: sandbox, index: index)
        let result = try await tool.execute(arguments: #"{"path": "App.swift"}"#)
        XCTAssertTrue(result.contains("1: struct MyApp"))
        XCTAssertTrue(result.contains("2: func run"))
    }
}
SWIFT

echo "S2b: Инструменты созданы."
