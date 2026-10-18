//
//  OpenRouterTransport.swift
//  Bosun
//
//  Created by Dmitry on 18.10.2026.
//

import Foundation

struct HTTPRequest: Sendable {
    var url: URL
    var method: String = "GET"
    var headers: [String: String] = [:]
    var body: Data?
}

struct HTTPResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var body: AsyncThrowingStream<Data, Error>
}

protocol OpenRouterTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
