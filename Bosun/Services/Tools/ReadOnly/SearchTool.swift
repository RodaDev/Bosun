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
