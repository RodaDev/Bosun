import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    private let settings: SettingsStore
    private let keychain: KeychainStore

    var hasKey: Bool { settings.hasAPIKey }

    init(settings: SettingsStore, keychain: KeychainStore) {
        self.settings = settings
        self.keychain = keychain
    }

    func removeAPIKey() {
        keychain.deleteAPIKey()
        settings.hasAPIKey = false
    }
}
