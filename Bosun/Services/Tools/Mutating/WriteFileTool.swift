import Foundation

struct WriteFileTool: AgentTool {
    let sandbox: Sandbox
    
    var requiresApproval: Bool { true }
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "write_file",
            description: "Создает новый файл или ПОЛНОСТЬЮ перезаписывает существующий. Внимание: старые данные будут стерты.",
            parameters: [
                "path": ToolParameter(description: "Путь к файлу"),
                "content": ToolParameter(description: "Полное содержимое файла")
            ]
        )
    }
    
    struct Args: Decodable {
        let path: String
        let content: String
    }
    
    func prepareApproval(arguments: String) async throws -> ApprovalRequest? {
        let args = try decodeArgs(Args.self, from: arguments)
        let url = try await sandbox.resolve(args.path)
        
        // Пытаемся прочитать старое содержимое, если файл существует
        let oldContent = try? String(contentsOf: url, encoding: .utf8)
        
        return ApprovalRequest(
            toolName: definition.name,
            path: args.path,
            oldContent: oldContent,
            newContent: args.content
        )
    }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let url = try await sandbox.resolve(args.path)
        
        try args.content.write(to: url, atomically: true, encoding: .utf8)
        return "Файл \(args.path) успешно записан."
    }
}
