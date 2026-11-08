import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    private enum Keys {
        static let hasAPIKey = "hasAPIKey"
        static let defaultModelId = "defaultModelId"
        static let projectRootPath = "projectRootPath"
        static let maxIterations = "maxIterations"
    }

    private let defaults: UserDefaults

    var hasAPIKey: Bool { didSet { defaults.set(hasAPIKey, forKey: Keys.hasAPIKey) } }
    var defaultModelId: String? { didSet { defaults.set(defaultModelId, forKey: Keys.defaultModelId) } }
    var projectRootPath: String? { didSet { defaults.set(projectRootPath, forKey: Keys.projectRootPath) } }
    
    // НОВОЕ: Лимит итераций (по умолчанию 50)
    var maxIterations: Int { didSet { defaults.set(maxIterations, forKey: Keys.maxIterations) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasAPIKey = defaults.bool(forKey: Keys.hasAPIKey)
        self.defaultModelId = defaults.string(forKey: Keys.defaultModelId)
        self.projectRootPath = defaults.string(forKey: Keys.projectRootPath)
        
        let savedIterations = defaults.integer(forKey: Keys.maxIterations)
        self.maxIterations = savedIterations == 0 ? 50 : savedIterations // Если 0, ставим 50 по умолчанию
    }
}
