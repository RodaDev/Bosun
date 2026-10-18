import Foundation

enum ConfirmationMode: String, Codable, CaseIterable {
    case always, session
}

enum BuildLogFormat: String, Codable, CaseIterable {
    case raw, summary
}

struct AppSettings: Codable, Equatable {
    var defaultModelId: String?
    var confirmationMode: ConfirmationMode = .always
    var buildLogFormat: BuildLogFormat = .summary
}
