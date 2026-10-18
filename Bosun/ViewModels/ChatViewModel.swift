import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    var draft: String = ""
    var isRunning: Bool = false

    private let settings: SettingsStore
    private let keychain: KeychainStore

    init(settings: SettingsStore, keychain: KeychainStore) {
        self.settings = settings
        self.keychain = keychain
    }
}
