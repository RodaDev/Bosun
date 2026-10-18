import Foundation
@testable import Bosun

final class MockTransport: OpenRouterTransport, @unchecked Sendable {
    var responseStatus: Int = 200
    var chunks: [Data] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let stream = AsyncThrowingStream<Data, Error> { cont in
            for c in chunks { cont.yield(c) }
            cont.finish()
        }
        return HTTPResponse(
            statusCode: responseStatus,
            headers: [:],
            body: stream
        )
    }
}
