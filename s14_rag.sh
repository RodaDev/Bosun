#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

mkdir -p Bosun/Services/RAG

# 1. Модель для SwiftData
cat > Bosun/Models/CodeChunk.swift <<'SWIFT'
import Foundation
import SwiftData

@Model
final class CodeChunk {
    @Attribute(.unique) var id: UUID
    var filePath: String
    var content: String
    var startLine: Int
    var endLine: Int
    var vector: [Float]
    
    init(filePath: String, content: String, startLine: Int, endLine: Int, vector: [Float]) {
        self.id = UUID()
        self.filePath = filePath
        self.content = content
        self.startLine = startLine
        self.endLine = endLine
        self.vector = vector
    }
}
SWIFT

# 2. Обновляем OpenRouterClient (Добавляем Embeddings)
# Вам нужно вставить эти методы в OpenRouterClient.swift
cat > /tmp/embed_patch.swift <<'SWIFT'
    // Вставляем в OpenRouterClient
    func fetchEmbedding(text: String) async throws -> [Float] {
        let payload: [String: Any] = [
            "model": "openai/text-embedding-3-small",
            "input": text
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        
        let request = HTTPRequest(
            url: baseURL.appending(path: "embeddings"),
            method: "POST",
            headers: [
                "Authorization": "Bearer \(try apiKey())",
                "Content-Type": "application/json"
            ],
            body: data
        )
        let response = try await transport.send(request)
        let responseData = try await collect(response.body)
        
        guard response.statusCode == 200 else {
            throw OpenRouterError.server(status: response.statusCode, body: String(data: responseData, encoding: .utf8) ?? "")
        }
        
        struct EmbeddingResponse: Decodable {
            struct Data: Decodable {
                let embedding: [Float]
            }
            let data: [Data]
        }
        
        let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: responseData)
        return decoded.data.first?.embedding ?? []
    }
SWIFT

# 3. VectorMath (Accelerate)
cat > Bosun/Services/RAG/VectorMath.swift <<'SWIFT'
import Foundation
import Accelerate

struct VectorMath {
    // Косинусное сходство между двумя векторами
    static func cosineSimilarity(a: [Float], b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dotProduct / denom : 0
    }
}
SWIFT

# 4. IndexerService
cat > Bosun/Services/RAG/IndexerService.swift <<'SWIFT'
import Foundation
import SwiftData

actor IndexerService {
    private let sandbox: Sandbox
    private let client: OpenRouterClient
    
    init(sandbox: Sandbox, client: OpenRouterClient) {
        self.sandbox = sandbox
        self.client = client
    }
    
    // Простая нарезка по символам с перекрытием
    private func chunkText(_ text: String, chunkSize: Int = 1500, overlap: Int = 200) -> [String] {
        var chunks: [String] = []
        var currentIndex = text.startIndex
        
        while currentIndex < text.endIndex {
            let endIndex = text.index(currentIndex, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[currentIndex..<endIndex])
            chunks.append(chunk)
            
            if endIndex == text.endIndex { break }
            currentIndex = text.index(endIndex, offsetBy: -overlap)
        }
        return chunks
    }
    
    func indexProject(context: ModelContext, progress: @escaping @Sendable (String) -> Void) async throws {
        // 1. Очищаем старый индекс
        try context.delete(model: CodeChunk.self)
        try context.save()
        
        let root = await sandbox.rootURL
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        
        var filesToIndex: [URL] = []
        for case let url as URL in enumerator {
            if ExcludedPaths.names.contains(where: { url.path.contains("/\($0)/") }) { continue }
            if url.pathExtension == "swift" || url.pathExtension == "md" || url.pathExtension == "json" {
                filesToIndex.append(url)
            }
        }
        
        progress("Найдено \(filesToIndex.count) файлов для индексации...")
        
        for (index, fileURL) in filesToIndex.enumerated() {
            let path = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            
            let textChunks = chunkText(content)
            progress("Индексация \(index + 1)/\(filesToIndex.count): \(path)")
            
            for chunk in textChunks {
                // В идеале нужно батчить по 50 штук, но для MVP делаем по одному
                if let vector = try? await client.fetchEmbedding(text: chunk) {
                    let codeChunk = CodeChunk(
                        filePath: path,
                        content: chunk,
                        startLine: 0, // Для простоты
                        endLine: 0,
                        vector: vector
                    )
                    context.insert(codeChunk)
                }
            }
            try context.save()
        }
        progress("Индексация завершена.")
    }
}
SWIFT

# 5. SemanticSearchTool
cat > Bosun/Services/RAG/SemanticSearchTool.swift <<'SWIFT'
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
SWIFT

echo "S14: RAG готов. Теперь нужно вручную добавить Embedding-метод в OpenRouterClient и обновить UI."
