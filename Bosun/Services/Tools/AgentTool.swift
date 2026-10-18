import Foundation

/// Схема параметров в формате JSON Schema (совместимо с OpenRouter/OpenAI)
struct ToolParameter: Codable, Sendable {
    let type: String
    let description: String
    let `enum`: [String]?
    
    init(type: String = "string", description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enum = enumValues
    }
    
    enum CodingKeys: String, CodingKey {
        case type, description
        case `enum`
    }
}

struct ToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let parameters: [String: ToolParameter]
}

protocol AgentTool: Sendable {
    var definition: ToolDefinition { get }
    func execute(arguments: String) async throws -> String
}

// Вспомогательная функция для парсинга аргументов
extension AgentTool {
    func decodeArgs<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "Tool", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF8 in arguments"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
