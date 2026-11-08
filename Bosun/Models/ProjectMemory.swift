import Foundation
import SwiftData

@Model
final class ProjectMemory {
    @Attribute(.unique) var id: UUID
    var projectPath: String
    var fact: String
    var createdAt: Date
    
    init(projectPath: String, fact: String) {
        self.id = UUID()
        self.projectPath = projectPath
        self.fact = fact
        self.createdAt = Date()
    }
}
