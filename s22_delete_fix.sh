#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

# 1. Обновляем PromptBuilder (Учим правильно удалять)
cat > Bosun/Services/Agent/PromptBuilder.swift <<'SWIFT'
import Foundation

struct PromptBuilder {
    static func buildSystemPrompt(tree: String?) -> String {
        var prompt = """
        Ты — Bosun, полезный ИИ-ассистент для разработки на macOS.
        Ты работаешь внутри проекта пользователя.
        
        """
        
        if let tree = tree {
            prompt += "Структура проекта:\n\(tree)\n\n"
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

# 2. Обновляем EditFileTool (Понятная ошибка при удалении)
cat > Bosun/Services/Tools/Mutating/EditFileTool.swift <<'SWIFT'
import Foundation

struct EditFileTool: AgentTool {
    let sandbox: Sandbox
    
    var requiresApproval: Bool { true }
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "edit_file",
            description: "Заменяет конкретный фрагмент текста в файле. Чтобы УДАЛИТЬ код, передай new_string как пустую строку \"\".",
            parameters: [
                "path": ToolParameter(description: "Путь к файлу"),
                "old_string": ToolParameter(description: "Точный текст, который нужно найти и заменить"),
                "new_string": ToolParameter(description: "Новый текст. Передай \"\", чтобы удалить.")
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
        
        if args.old_string == args.new_string {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Ошибка: old_string и new_string идентичны. Ты не внес никаких изменений. Если хочешь удалить код, передай new_string как пустую строку \"\"."])
        }
        if args.old_string.isEmpty {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Ошибка: old_string не может быть пустым."])
        }
        
        let url = try await sandbox.resolve(args.path)
        try await sandbox.validateExists(url)
        
        let originalContent = try String(contentsOf: url, encoding: .utf8)
        var content = originalContent
        
        var occurrences = content.components(separatedBy: args.old_string).count - 1
        
        // Фолбэк 1: Игнорируем пробелы
        if occurrences == 0 {
            let strippedOld = args.old_string.components(separatedBy: .whitespacesAndNewlines).joined()
            let lines = content.components(separatedBy: .newlines)
            let oldLines = args.old_string.components(separatedBy: .newlines)
            
            if lines.count >= oldLines.count {
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
        }
        
        if occurrences == 0 {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Строка old_string не найдена в файле. Попробуй скопировать текст точнее."])
        }
        if occurrences > 1 {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Строка old_string встречается \(occurrences) раз. Нужен более уникальный фрагмент."])
        }
        
        if content == originalContent {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Ошибка: Замена не внесла изменений в файл. Ты передал new_string, который совпадает с old_string. Если ты хочешь удалить код, передай new_string как пустую строку \"\"."])
        }
        
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Файл \(args.path) успешно изменен."
    }
}
SWIFT

echo "S22: Правильное удаление кода готово."
