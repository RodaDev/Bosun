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
