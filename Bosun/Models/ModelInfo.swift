//
//  ModelInfo.swift
//  Bosun
//
//  Created by Dmitry on 18.10.2026.
//

import Foundation

struct ModelInfo: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let supportsTools: Bool
    let contextLength: Int?

    var displayName: String { name.isEmpty ? id : name }
}

extension ModelInfo {
    /// Ответ OpenRouter `/api/v1/models`
    struct Wire: Codable, Sendable {
        let id: String
        let name: String?
        let contextLength: Int?
        let supportedParameters: [String]?

        enum CodingKeys: String, CodingKey {
            case id, name
            case contextLength = "context_length"
            case supportedParameters = "supported_parameters"
        }

        func toModel() -> ModelInfo {
            ModelInfo(
                id: id,
                name: name ?? id,
                supportsTools: supportedParameters?.contains("tools") ?? false,
                contextLength: contextLength
            )
        }
    }
}
