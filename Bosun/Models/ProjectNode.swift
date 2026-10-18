import Foundation

struct ProjectNode: Identifiable, Hashable, Sendable {
    let id: URL
    let name: String
    let isDirectory: Bool
    var children: [ProjectNode]?
    var isModified: Bool = false

    var url: URL { id }
}
