import Foundation

enum AttachmentType: String, Codable, Sendable {
    case image, text
}

struct ChatAttachment: Identifiable, Hashable, Sendable, Codable { // <-- Добавили Codable
    let id: UUID
    let fileName: String
    let type: AttachmentType
    let data: Data
    
    init(id: UUID = UUID(), fileName: String, type: AttachmentType, data: Data) {
        self.id = id
        self.fileName = fileName
        self.type = type
        self.data = data
    }
    
    var base64Image: String? {
        guard type == .image else { return nil }
        let mime = fileName.lowercased().hasSuffix("png") ? "image/png" : "image/jpeg"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }
    
    var textContent: String? {
        guard type == .text else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
