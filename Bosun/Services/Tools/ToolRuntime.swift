import Foundation

struct ApprovalRequest: Identifiable, Sendable {
    let id: UUID = UUID()
    let toolName: String
    let path: String
    let oldContent: String?
    let newContent: String
}

actor ToolRuntime {
    private let registry: ToolRegistry
    
    init(registry: ToolRegistry) {
        self.registry = registry
    }
    
    var openRouterTools: [[String: Any]] {
        registry.openRouterSchema
    }
    
    /// Выполняет инструмент. Для мутирующих вызывает approvalClosure перед записью.
    /// Просто выполняет инструмент (без запросов, так как запросы уже были собраны пачкой)
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
    
    func prepareApprovals(for calls: [ToolCall]) async -> [ApprovalRequest] {
        var requests: [ApprovalRequest] = []
        for call in calls {
            guard let tool = registry.get(call.function.name), tool.requiresApproval else { continue }
            if let req = try? await tool.prepareApproval(arguments: call.function.arguments) {
                requests.append(req)
            }
        }
        return requests
    }
    
    private func prepareApprovalRequest(call: ToolCall, tool: AgentTool) async throws -> ApprovalRequest {
        let data = call.function.arguments.data(using: .utf8)!
        
        if tool.definition.name == "edit_file" {
            struct Args: Decodable { let path: String, old_string: String, new_string: String }
            let args = try JSONDecoder().decode(Args.self, from: data)
            return ApprovalRequest(toolName: "edit_file", path: args.path, oldContent: args.old_string, newContent: args.new_string)
        } else if tool.definition.name == "write_file" {
            struct Args: Decodable { let path: String, content: String }
            let args = try JSONDecoder().decode(Args.self, from: data)
            // Для write_file нет "старого" текста (он перезаписывает), поэтому oldContent nil
            return ApprovalRequest(toolName: "write_file", path: args.path, oldContent: nil, newContent: args.content)
        }
        
        throw NSError(domain: "Runtime", code: 0, userInfo: [NSLocalizedDescriptionKey: "Неизвестный мутирующий инструмент"])
    }
}
