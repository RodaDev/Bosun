import XCTest
@testable import Bosun

final class SmokeTests: XCTestCase {
    func testKeychainRoundTrip() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Keychain недоступен без подписи в CI"
        )
        let store = KeychainStore()
        try store.saveAPIKey("test-key")
        XCTAssertEqual(store.loadAPIKey(), "test-key")
        store.deleteAPIKey()
        XCTAssertNil(store.loadAPIKey())
    }

    @MainActor
    func testSettingsDefaults() {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.hasAPIKey)
        XCTAssertNil(store.defaultModelId)
        XCTAssertNil(store.projectRootPath)
    }
}
