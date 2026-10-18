import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    let settings: SettingsStore
    let keychain: KeychainStore
    let chatVM: ChatViewModel
    let settingsVM: SettingsViewModel

    init() {
        let settings = SettingsStore()
        let keychain = KeychainStore()
        self.settings = settings
        self.keychain = keychain
        self.chatVM = ChatViewModel(settings: settings, keychain: keychain)
        self.settingsVM = SettingsViewModel(settings: settings, keychain: keychain)
    }
}
