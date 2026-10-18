import Foundation

struct EditFileTool: AgentTool {
    let sandbox: Sandbox
    
    var requiresApproval: Bool { true }
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "edit_file",
            description: "Заменяет конкретный фрагмент текста в файле. Идеально для правок. 'old_string' должен точно совпадать с текстом в файле и быть уникальным.",
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
        return ApprovalRequest(
            toolName: definition.name,
            path: args.path,
            oldContent: args.old_string, // Показываем, что удаляется
            newContent: args.new_string
        )
    }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let url = try await sandbox.resolve(args.path)
        try await sandbox.validateExists(url)
        
        var content = try String(contentsOf: url, encoding: .utf8)
        
        // Проверка на уникальность
        let occurrences = content.components(separatedBy: args.old_string).count - 1
        if occurrences == 0 {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Строка old_string не найдена в файле."])
        }
        if occurrences > 1 {
            throw NSError(domain: "EditFile", code: 0, userInfo: [NSLocalizedDescriptionKey: "Строка old_string встречается \(occurrences) раз. Нужен более уникальный фрагмент."])
        }
        
        content = content.replacingOccurrences(of: args.old_string, with: args.new_string)
        try content.write(to: url, atomically: true, encoding: .utf8)
        
        return "Файл \(args.path) успешно изменен."
    }
}
