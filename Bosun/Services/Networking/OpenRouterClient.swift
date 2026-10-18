//
//  OpenRouterClient.swift
//  Bosun
//
//  Created by Dmitry on 18.10.2026.
//

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

struct StreamChunk: Sendable {
    var textDelta: String
    var promptTokens: Int?
    var completionTokens: Int?
    var cachedTokens: Int?
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

    func streamCompletion(
        model: String,
        messages: [ChatMessage]
    ) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        let payload = ChatCompletionRequest(
            model: model,
            messages: messages.map(\.wire),
            stream: true
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
                do {
                    for try await raw in response.body {
                        for payload in parser.feed(raw) {
                            if payload == "[DONE]" {
                                continuation.yield(StreamChunk(textDelta: "", isDone: true))
                                continuation.finish()
                                return
                            }
                            if let chunk = Self.decodeChunk(payload) {
                                continuation.yield(chunk)
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

    private func apiKey() throws -> String {
        guard let key = keychain.loadAPIKey(), !key.isEmpty else {
            throw OpenRouterError.missingAPIKey
        }
        return key
    }

    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var out = Data()
        for try await d in stream { out.append(d) }
        return out
    }

    private static func decodeChunk(_ payload: String) -> StreamChunk? {
        struct Wire: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
            }
            struct Usage: Decodable {
                let prompt_tokens: Int?
                let completion_tokens: Int?
                let prompt_tokens_details: Details?
                struct Details: Decodable { let cached_tokens: Int? }
            }
            let choices: [Choice]?
            let usage: Usage?
        }
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Wire.self, from: data) else {
            return nil
        }
        let text = decoded.choices?.first?.delta?.content ?? ""
        return StreamChunk(
            textDelta: text,
            promptTokens: decoded.usage?.prompt_tokens,
            completionTokens: decoded.usage?.completion_tokens,
            cachedTokens: decoded.usage?.prompt_tokens_details?.cached_tokens
        )
    }
}
