import Foundation

struct ReadFileTool: AgentTool {
    let sandbox: Sandbox
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "read_file",
            description: "Читает содержимое файла. По умолчанию отдает только первые 100 строк для экономии контекста. Используй start_line для чтения остального.",
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
        
        // ЛЕНИВОЕ ЧТЕНИЕ: по умолчанию отдаем только 100 строк
        let end = min(totalLines, start + 100)
        let slice = lines[start..<end]
        
        var result = slice.enumerated().map { "\(start + $0.offset + 1): \($0.element)" }.joined(separator: "\n")
        
        if end < totalLines {
            result += "\n...[УСЕЧЕНО: показано 100 строк из \(totalLines). Для продолжения используй start_line: \(end + 1)]"
        }
        
        return result
    }
}
