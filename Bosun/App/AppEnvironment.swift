import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    let settings: SettingsStore
    let keychain: KeychainStore
    let openRouter: OpenRouterClient
    let chatVM: ChatViewModel
    let modelPickerVM: ModelPickerViewModel
    let settingsVM: SettingsViewModel

    var sandbox: Sandbox?
    var projectRoot: URL? {
        didSet {
            if let root = projectRoot {
                sandbox = Sandbox(rootURL: root)
                settings.projectRootPath = root.path
            } else {
                sandbox = nil
                settings.projectRootPath = nil
            }
        }
    }

    init() {
        let settings = SettingsStore()
        let keychain = KeychainStore()
        let transport = URLSessionTransport()
        let client = OpenRouterClient(transport: transport, keychain: keychain)

        self.settings = settings
        self.keychain = keychain
        self.openRouter = client
        self.chatVM = ChatViewModel(settings: settings, keychain: keychain, client: client)
        self.modelPickerVM = ModelPickerViewModel(client: client)
        self.settingsVM = SettingsViewModel(settings: settings, keychain: keychain)

        if let path = settings.projectRootPath {
            self.projectRoot = URL(fileURLWithPath: path)
        }
    }
}
