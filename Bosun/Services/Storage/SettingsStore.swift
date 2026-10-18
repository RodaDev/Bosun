import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    private enum Keys {
        static let hasAPIKey = "hasAPIKey"
        static let defaultModelId = "defaultModelId"
        static let projectRootPath = "projectRootPath"
    }

    private let defaults: UserDefaults

    var hasAPIKey: Bool { didSet { defaults.set(hasAPIKey, forKey: Keys.hasAPIKey) } }
    var defaultModelId: String? { didSet { defaults.set(defaultModelId, forKey: Keys.defaultModelId) } }
    var projectRootPath: String? { didSet { defaults.set(projectRootPath, forKey: Keys.projectRootPath) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasAPIKey = defaults.bool(forKey: Keys.hasAPIKey)
        self.defaultModelId = defaults.string(forKey: Keys.defaultModelId)
        self.projectRootPath = defaults.string(forKey: Keys.projectRootPath)
    }
}
