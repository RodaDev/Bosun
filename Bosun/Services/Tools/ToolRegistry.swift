import Foundation

final class ToolRegistry: Sendable {
    private let tools: [String: AgentTool]
    
    init(tools: [AgentTool]) {
        var dict: [String: AgentTool] = [:]
        for tool in tools {
            dict[tool.definition.name] = tool
        }
        self.tools = dict
    }
    
    func get(_ name: String) -> AgentTool? {
        tools[name]
    }
    
    /// Возвращает массив словарей для поля `tools` в запросе OpenRouter
    var openRouterSchema: [[String: Any]] {
        tools.values.map { tool in
            let def = tool.definition
            var props: [String: Any] = [:]
            var required: [String] = []
            
            for (key, param) in def.parameters {
                var p: [String: Any] = ["type": param.type, "description": param.description]
                if let enumVals = param.enum { p["enum"] = enumVals }
                props[key] = p
                required.append(key) // Для простоты все параметры обязательны
            }
            
            let parametersSchema: [String: Any] = [
                "type": "object",
                "properties": props,
                "required": required
            ]
            
            return [
                "type": "function",
                "function": [
                    "name": def.name,
                    "description": def.description,
                    "parameters": parametersSchema
                ]
            ]
        }
    }
}
