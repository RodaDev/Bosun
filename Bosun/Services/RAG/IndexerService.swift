import Foundation
import SwiftData

actor IndexerService {
    private let sandbox: Sandbox
    private let client: OpenRouterClient
    private let gitService: GitService
    
    init(sandbox: Sandbox, client: OpenRouterClient, gitService: GitService) {
        self.sandbox = sandbox
        self.client = client
        self.gitService = gitService
    }
    
    private func chunkText(_ text: String, chunkSize: Int = 1500, overlap: Int = 200) -> [String] {
        var chunks: [String] = []
        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            let endIndex = text.index(currentIndex, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[currentIndex..<endIndex]))
            if endIndex == text.endIndex { break }
            currentIndex = text.index(endIndex, offsetBy: -overlap)
        }
        return chunks
    }
    
    func indexProject(context: ModelContext, progress: @escaping @Sendable (String) -> Void) async throws {
        let root = sandbox.rootURL
        
        // 1. Получаем список измененных файлов (через Git, либо через сканирование)
        var filesToIndex: [URL] = []
        
        let gitChanged = await gitService.getChangedFiles()
        if !gitChanged.isEmpty {
            progress("Git: найдено \(gitChanged.count) измененных файлов...")
            for path in gitChanged {
                let url = root.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path) && (url.pathExtension == "swift" || url.pathExtension == "md") {
                    filesToIndex.append(url)
                }
            }
        } else {
            // Фолбэк по mtime, если Git пуст или нет репозитория
            let existingChunks = try context.fetch(FetchDescriptor<CodeChunk>())
            var indexedFiles: [String: Date] = [:]
            for chunk in existingChunks {
                indexedFiles[chunk.filePath] = chunk.fileModifiedDate
            }
            
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            for case let url as URL in enumerator {
                if ExcludedPaths.names.contains(where: { url.path.contains("/\($0)/") }) { continue }
                guard url.pathExtension == "swift" || url.pathExtension == "md" else { continue }
                
                let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                
                // Если файла нет в базе ИЛИ он изменен после последней индексации
                if let existingDate = indexedFiles[path] {
                    if modDate > existingDate {
                        filesToIndex.append(url)
                    }
                } else {
                    filesToIndex.append(url)
                }
            }
        }
        
        if filesToIndex.isEmpty {
            progress("Все файлы актуальны. Индексация не требуется.")
            return
        }
        
        // 2. Удаляем старые чанки для этих файлов
        let pathsToIndex = filesToIndex.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
        let existingChunks = try context.fetch(FetchDescriptor<CodeChunk>())
        for chunk in existingChunks {
            if pathsToIndex.contains(chunk.filePath) {
                context.delete(chunk)
            }
        }
        try context.save()
        
        progress("Индексация \(filesToIndex.count) файлов...")
        
        // 3. Индексируем
        for (index, fileURL) in filesToIndex.enumerated() {
            let path = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let textChunks = chunkText(content)
            
            progress("Индексация \(index + 1)/\(filesToIndex.count): \(path)")
            
            for chunk in textChunks {
                if let vector = try? await client.fetchEmbedding(text: chunk) {
                    let codeChunk = CodeChunk(filePath: path, content: chunk, fileModifiedDate: modDate, vector: vector)
                    context.insert(codeChunk)
                }
            }
            try context.save()
        }
        progress("Индексация завершена.")
    }
}
