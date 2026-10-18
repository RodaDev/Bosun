import Foundation

struct Symbol: Identifiable, Hashable, Sendable {
    var id: String { "\(fileURL.path):\(line):\(name)" }
    let name: String
    let kind: String
    let fileURL: URL
    let line: Int
}
