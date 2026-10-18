import Foundation

actor ToolRuntime {
    private let registry: ToolRegistry
    
    init(registry: ToolRegistry) {
        self.registry = registry
    }
    
    var openRouterTools: [[String: Any]] {
        registry.openRouterSchema
    }
    
    func execute(_ call: ToolCall) async -> ToolResult {
        guard let tool = registry.get(call.function.name) else {
            return ToolResult.error(call.id, "Инструмент '\(call.function.name)' не найден")
        }
        
        do {
            let output = try await tool.execute(arguments: call.function.arguments)
            return ToolResult(toolCallId: call.id, content: output, isError: false)
        } catch {
            return ToolResult.error(call.id, error.localizedDescription)
        }
    }
}
