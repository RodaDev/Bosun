import Foundation

actor SymbolIndex {
    private var symbolsByFile: [URL: [Symbol]] = [:]
    private let rootURL: URL
    
    init(rootURL: URL) {
        self.rootURL = rootURL
    }
    
    func rebuild() async throws {
        symbolsByFile.removeAll()
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: nil) else { return }
        
        for case let fileURL as URL in enumerator {
            if ExcludedPaths.names.contains(where: { fileURL.path.contains("/\($0)/") }) {
                enumerator.skipDescendants()
                continue
            }
            guard fileURL.pathExtension == "swift" else { continue }
            
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                let symbols = SymbolParser.parse(fileURL: fileURL, content: content)
                if !symbols.isEmpty {
                    // Нормализуем путь перед сохранением
                    let standardized = fileURL.standardizedFileURL.resolvingSymlinksInPath()
                    symbolsByFile[standardized] = symbols
                }
            }
        }
    }
    
    func find(name: String) -> [Symbol] {
        symbolsByFile.values.flatMap { $0 }.filter { $0.name.localizedCaseInsensitiveContains(name) }
    }
    
    func listAll() -> [Symbol] {
        symbolsByFile.values.flatMap { $0 }
    }
    
    func listForFile(_ url: URL) -> [Symbol] {
        // Нормализуем путь перед поиском
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        return symbolsByFile[standardized] ?? []
    }
}
