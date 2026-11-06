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
