import Foundation
import SwiftData

struct SemanticSearchTool: AgentTool {
    let client: OpenRouterClient
    let context: ModelContext
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "semantic_search",
            description: "Ищет код по смыслу. Используй, если не знаешь точного названия метода или переменной.",
            parameters: ["query": ToolParameter(description: "Вопрос или описание того, что ищешь")]
        )
    }
    
    struct Args: Decodable { let query: String }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        
        guard let queryVector = try? await client.fetchEmbedding(text: args.query) else {
            return "Ошибка получения вектора для запроса."
        }
        
        // Достаем все чанки из SwiftData
        let descriptor = FetchDescriptor<CodeChunk>()
        let allChunks = try context.fetch(descriptor)
        
        if allChunks.isEmpty { return "База знаний пуста. Попросите пользователя нажать 'Проиндексировать проект'." }
        
        // Считаем сходство
        var scored: [(chunk: CodeChunk, score: Float)] = []
        for chunk in allChunks {
            let score = VectorMath.cosineSimilarity(a: queryVector, b: chunk.vector)
            scored.append((chunk, score))
        }
        
        // Сортируем и берем топ-5
        let top5 = scored.sorted { $0.score > $1.score }.prefix(5)
        
        var result = "Результаты семантического поиска:\n\n"
        for (chunk, score) in top5 {
            result += "Файл: \(chunk.filePath) (Совпадение: \(String(format: "%.2f", score * 100))%)\n"
            result += "\(chunk.content)\n---\n"
        }
        return result
    }
}
