//
//  SSEParser.swift
//  Bosun
//
//  Created by Dmitry on 18.10.2026.
//

import Foundation

/// Парсит поток `data: {...}\n\n` в отдельные строки-payload.
/// Не знает про JSON и OpenRouter — тестируется отдельно.
struct SSEParser {
    private var buffer = ""

    mutating func feed(_ data: Data) -> [String] {
        guard let chunk = String(data: data, encoding: .utf8) else { return [] }
        buffer.append(chunk)

        var events: [String] = []
        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" {
                    events.append("[DONE]")
                } else if !payload.isEmpty {
                    events.append(payload)
                }
            }
        }
        return events
    }
}
