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
