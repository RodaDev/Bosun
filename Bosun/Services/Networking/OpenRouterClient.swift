import Foundation

enum OpenRouterError: Error, LocalizedError {
    case missingAPIKey
    case unauthorized
    case server(status: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "OpenRouter API key не задан"
        case .unauthorized: return "OpenRouter: 401 Unauthorized — проверьте ключ"
        case .server(let status, let body): return "OpenRouter: HTTP \(status) — \(body.prefix(200))"
        case .decoding(let msg): return "OpenRouter: ошибка разбора ответа — \(msg)"
        }
    }
}

struct UsageInfo: Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let cachedTokens: Int
}

struct StreamChunk: Sendable {
    var textDelta: String = ""
    var toolCalls: [ToolCall]? = nil
    var usage: UsageInfo? = nil
    var isDone: Bool = false
}

actor OpenRouterClient {
    private let transport: OpenRouterTransport
    private let keychain: KeychainStore
    private let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    init(transport: OpenRouterTransport, keychain: KeychainStore) {
        self.transport = transport
        self.keychain = keychain
    }

    func fetchModels() async throws -> [ModelInfo] {
        let request = HTTPRequest(
            url: baseURL.appending(path: "models"),
            method: "GET",
            headers: ["Authorization": "Bearer \(try apiKey())"]
        )
        let response = try await transport.send(request)
        let data = try await collect(response.body)
        guard response.statusCode == 200 else {
            throw OpenRouterError.server(status: response.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        struct ModelsResponse: Decodable { let data: [ModelInfo.Wire] }
        do {
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data.map { $0.toModel() }
        } catch {
            throw OpenRouterError.decoding("\(error)")
        }
    }
    
    func fetchCredits() async throws -> Double {
        let request = HTTPRequest(
            url: baseURL.appending(path: "credits"),
            method: "GET",
            headers: ["Authorization": "Bearer \(try apiKey())"]
        )
        let response = try await transport.send(request)
        let data = try await collect(response.body)
        guard response.statusCode == 200 else {
            throw OpenRouterError.server(status: response.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            let decoded = try JSONDecoder().decode(TotalCreditsResponse.self, from: data)
            return decoded.data.total_credits - decoded.data.total_usage
        } catch {
            throw OpenRouterError.decoding("\(error)")
        }
    }

    func streamCompletion(
        model: String,
        messages: [ChatMessage],
        tools: [[String: Any]]?
    ) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        let payload = ChatCompletionRequest(
            model: model,
            messages: messages.map(\.wire),
            stream: true,
            tools: tools?.map { AnyCodable($0) }
        )
        let data = try JSONEncoder().encode(payload)

        let request = HTTPRequest(
            url: baseURL.appending(path: "chat/completions"),
            method: "POST",
            headers: [
                "Authorization": "Bearer \(try apiKey())",
                "Content-Type": "application/json",
                "HTTP-Referer": "https://github.com/bosun-app/bosun",
                "X-Title": "Bosun"
            ],
            body: data
        )
        let response = try await transport.send(request)
        guard response.statusCode == 200 else {
            let errBody = try await collect(response.body)
            throw OpenRouterError.server(
                status: response.statusCode,
                body: String(data: errBody, encoding: .utf8) ?? ""
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                var toolCallBuilders: [Int: (id: String, name: String, args: String)] = [:]
                
                do {
                    for try await raw in response.body {
                        for payload in parser.feed(raw) {
                            let isDone = Self.processPayload(
                                payload,
                                builders: &toolCallBuilders,
                                continuation: continuation
                            )
                            if isDone {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func processPayload(
        _ payload: String,
        builders: inout [Int: (id: String, name: String, args: String)],
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) -> Bool {
        if payload == "[DONE]" {
            let sortedCalls = builders.sorted { $0.key < $1.key }.map { (_, builder) in
                ToolCall(
                    id: builder.id,
                    type: "function",
                    function: ToolCall.Function(
                        name: builder.name,
                        arguments: sanitizeArguments(builder.args)
                    )
                )
            }
            if !sortedCalls.isEmpty {
                continuation.yield(StreamChunk(toolCalls: sortedCalls))
            }
            continuation.yield(StreamChunk(isDone: true))
            return true
        }
        
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(WireChunk.self, from: data) else {
            return false
        }
        
        if let text = chunk.choices?.first?.delta?.content, !text.isEmpty {
            continuation.yield(StreamChunk(textDelta: text))
        }
        
        if let tcs = chunk.choices?.first?.delta?.tool_calls {
            for tc in tcs {
                var builder = builders[tc.index] ?? (id: tc.id ?? UUID().uuidString, name: "", args: "")
                if let n = tc.function?.name, !n.isEmpty { builder.name = n }
                if let a = tc.function?.arguments { builder.args += a }
                builders[tc.index] = builder
            }
        }
        
        // Парсим usage (обычно приходит в последнем чанке)
        if let u = chunk.usage {
            continuation.yield(StreamChunk(usage: UsageInfo(promptTokens: u.prompt_tokens ?? 0, completionTokens: u.completion_tokens ?? 0, cachedTokens: u.prompt_tokens_details?.cached_tokens ?? 0)))
        }
        
        return false
    }

    private static func sanitizeArguments(_ raw: String) -> String {
        var args = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if args.hasPrefix("```json") {
            args = args.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        } else if args.hasPrefix("```") {
            args = args.replacingOccurrences(of: "```", with: "")
        }
        args = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if args.isEmpty { return "{}" }
        if let data = args.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) == nil { return "{}" }
        return args
    }

    private func apiKey() throws -> String {
        guard let key = keychain.loadAPIKey(), !key.isEmpty else { throw OpenRouterError.missingAPIKey }
        return key
    }

    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var out = Data()
        for try await d in stream { out.append(d) }
        return out
    }
}

struct WireChunk: Decodable {
    let choices: [Choice]?
    let usage: Usage?
    struct Choice: Decodable {
        let delta: Delta?
    }
    struct Delta: Decodable {
        let content: String?
        let tool_calls: [WireToolCall]?
    }
    struct WireToolCall: Decodable {
        let index: Int
        let id: String?
        let function: WireFunction?
    }
    struct WireFunction: Decodable {
        let name: String?
        let arguments: String?
    }
    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let prompt_tokens_details: PromptDetails?
    }
    struct PromptDetails: Decodable {
        let cached_tokens: Int?
    }
}

struct CreditsResponse: Decodable {
    let data: CreditsData
    struct CreditsData: Decodable {
        let limit: Double?
        let usage: Double?
        let limit_remaining: Double?
    }
}

struct TotalCreditsResponse: Decodable {
    let data: Data
    
    struct Data: Decodable {
        let total_credits: Double
        let total_usage: Double
    }
}
