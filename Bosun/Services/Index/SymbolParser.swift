import Foundation

struct SymbolParser {
    /// Очень простой regex-парсер верхнеуровневых типов и функций
    static func parse(fileURL: URL, content: String) -> [Symbol] {
        var symbols: [Symbol] = []
        let lines = content.components(separatedBy: .newlines)
        
        // Ищем struct, class, enum, protocol, func, var, let (учитывая отступы)
        let pattern = #"^\s*(?:public\s+|private\s+|internal\s+|fileprivate\s+)?(struct|class|enum|protocol|extension|func|var|let|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        
        for (index, line) in lines.enumerated() {
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex.firstMatch(in: line, range: nsRange) {
                if let kindRange = Range(match.range(at: 1), in: line),
                   let nameRange = Range(match.range(at: 2), in: line) {
                    let kind = String(line[kindRange])
                    let name = String(line[nameRange])
                    symbols.append(Symbol(
                        name: name,
                        kind: kind,
                        fileURL: fileURL,
                        line: index + 1
                    ))
                }
            }
        }
        return symbols
    }
}
