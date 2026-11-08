import Foundation
import SwiftData

struct UpdateMemoryTool: AgentTool {
    let projectRoot: URL
    let context: ModelContext
    
    var requiresApproval: Bool { false } // Память — это безопасно, подтверждение не нужно
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "update_memory",
            description: "Сохраняет важный архитектурный факт или правило в память проекта. Используй, когда узнаешь что-то важное о кодовой базе.",
            parameters: [
                "fact": ToolParameter(description: "Краткий факт (например, 'Мы используем паттерн MVVM. AppDependencies нельзя менять напрямую')")
            ]
        )
    }
    
    struct Args: Decodable { let fact: String }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let path = projectRoot.path
        
        let memory = ProjectMemory(projectPath: path, fact: args.fact)
        context.insert(memory)
        try context.save()
        
        return "Факт успешно сохранен в память проекта."
    }
}
