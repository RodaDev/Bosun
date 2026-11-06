#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

cat > Bosun/Services/Tools/Mutating/EditFileTool.swift <<'SWIFT'
import Foundation

struct EditFileTool: AgentTool {
    let sandbox: Sandbox
    
    var requiresApproval: Bool { true }
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "edit_file",
            description: "Заменяет конкретный фрагмент текста. Чтобы удалить структуру/функцию, передай только её заголовок (например 'struct MyView {') и пустой new_string — система сама удалит всё до закрывающей скобки.",
            parameters: [
                "path": ToolParameter(description: "Путь к файлу"),
                "old_string": ToolParameter(description: "Текст для поиска"),
                "new_string": ToolParameter(description: "Текст для замены (или пустая строка для удаления)")
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
        
        // Если old == new, считаем что это удаление
        var finalNewString = args.new_string
        if args.old_string == args.new_string {
            finalNewString = ""
        }
        
        let url = try await sandbox.resolve(args.path)
        try await sandbox.validateExists(url)
        
        let originalContent = try String(contentsOf: url, encoding: .utf8)
        var content = originalContent
        
        var targetOldString = args.old_string
        
        // УМНАЯ ЗАМЕНА: Если агент пытается удалить только заголовок структуры/функции,
        // мы автоматически расширяем old_string до закрывающей скобки.
        if finalNewString.isEmpty && targetOldString.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("{") {
            let lines = content.components(separatedBy: .newlines)
            let oldLines = targetOldString.components(separatedBy: .newlines)
            
            // Ищем, с какой строки начинается структура
            var startIndex = -1
            for i in 0..<lines.count {
                if lines[i].contains(targetOldString) {
                    startIndex = i
                    break
                }
            }
            
            if startIndex != -1 {
                var braceCount = 0
                var foundOpening = false
                var endIndex = startIndex
                
                for i in startIndex..<lines.count {
                    for char in lines[i] {
                        if char == "{" { braceCount += 1; foundOpening = true }
                        else if char == "}" { braceCount -= 1 }
                    }
                    if foundOpening && braceCount == 0 {
                        endIndex = i
                        break
                    }
                }
                
                // Если нашли закрывающую скобку, захватываем весь блок
                if endIndex > startIndex {
                    targetOldString = lines[startIndex...endIndex].joined(separator: "\n")
                }
            }
        }
        
        var occurrences = content.components(separatedBy: targetOldString).count - 1
        
        // Фолбэк 1: Игнорируем пробелы (если точное совпадение не найдено)
        if occurrences == 0 {
            let strippedOld = targetOldString.components(separatedBy: .whitespacesAndNewlines).joined()
            let lines = content.components(separatedBy: .newlines)
            let oldLines = targetOldString.components(separatedBy: .newlines)
            
            if lines.count >= oldLines.count {
                for i in 0...(lines.count - oldLines.count) {
                    let slice = lines[i..<(i + oldLines.count)].joined()
                    let strippedSlice = slice.components(separatedBy: .whitespacesAndNewlines).joined()
                    
                    if strippedSlice == strippedOld {
                        let newContent = Array(lines[..<i]) + [finalNewString] + Array(lines[(i + oldLines.count)...])
                        content = newContent.joined(separator: "\n")
                        occurrences = 1
                        break
                    }
                }
            }
        } else if occurrences == 1 {
            content = content.replacingOccurrences(of: targetOldString, with: finalNewString)
        }
        
        if occurrences == 0 {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Строка old_string не найдена. Попробуй прочитать файл через read_file или read_symbol, чтобы увидеть точный текст."])
        }
        if occurrences > 1 {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Строка old_string встречается \(occurrences) раз. Уточни контекст (добавь соседние строки)."])
        }
        
        // Чистим лишние пустые строки после удаления
        if finalNewString.isEmpty {
            content = content.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        
        try content.write(to: url, atomically: true, encoding: .utf8)
        
        if finalNewString.isEmpty {
            return "Код успешно удален. Если ты удалял структуру, она удалена целиком (включая внутренности)."
        }
        return "Файл \(args.path) успешно изменен."
    }
}
SWIFT

echo "S24: Умное удаление структур готово."
