import Foundation

struct FindSymbolTool: AgentTool {
    let index: SymbolIndex
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "find_symbol",
            description: "Ищет объявления классов, структур, функций в проекте по имени.",
            parameters: ["name": ToolParameter(description: "Имя символа (или его часть)")]
        )
    }
    
    struct Args: Decodable { let name: String }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let symbols = await index.find(name: args.name)
        
        if symbols.isEmpty { return "Символы не найдены" }
        
        return symbols.map {
            "\($0.fileURL.lastPathComponent):\($0.line): \($0.kind) \($0.name)"
        }.joined(separator: "\n")
    }
}
