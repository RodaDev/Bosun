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
