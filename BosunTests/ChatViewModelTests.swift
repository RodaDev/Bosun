//
//  ChatViewModelTests.swift
//  BosunTests
//
//  Created by Dmitry on 18.10.2026.
//

import XCTest
@testable import Bosun

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testStreamingAppendsAssistantMessage() async throws {
        let mock = MockTransport()
        mock.responseStatus = 200
        mock.chunks = [
            Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n".utf8),
            Data("data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n".utf8),
            Data("data: [DONE]\n\n".utf8)
        ]

        let keychain = KeychainStore()
        try? keychain.saveAPIKey("test-key")
        let client = OpenRouterClient(transport: mock, keychain: keychain)

        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let vm = ChatViewModel(settings: settings, keychain: keychain, client: client)
        vm.selectedModelId = "test/model"
        vm.draft = "hi"
        vm.send()

        let expectation = expectation(description: "stream finished")
        Task {
            while vm.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)

        XCTAssertEqual(vm.messages.map(\.content), ["hi", "Hello"])
        XCTAssertEqual(vm.messages.map(\.role), [.user, .assistant])
        keychain.deleteAPIKey()
    }
}
