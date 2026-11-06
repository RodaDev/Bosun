import Foundation
import SwiftData

@Model
final class CodeChunk {
    @Attribute(.unique) var id: UUID
    var filePath: String
    var content: String
    var fileModifiedDate: Date?
    var vector: [Float]
    
    init(filePath: String, content: String, fileModifiedDate: Date?, vector: [Float]) {
        self.id = UUID()
        self.filePath = filePath
        self.content = content
        self.fileModifiedDate = fileModifiedDate
        self.vector = vector
    }
}
