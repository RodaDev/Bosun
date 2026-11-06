import Foundation

actor GitService {
    private let rootURL: URL
    
    init(rootURL: URL) {
        self.rootURL = rootURL
    }
    
    private func runGit(_ arguments: [String]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = rootURL
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
    
    func undoAllChanges() async throws {
        _ = await runGit(["checkout", "."])
        _ = await runGit(["clean", "-fd"])
    }
    
    func getStatus() async -> String {
        let status = await runGit(["status", "--short"])
        return status.isEmpty ? "Нет изменений" : status
    }
    
    func getDiff() async -> String {
        return await runGit(["diff"])
    }
    
    /// Возвращает список измененных или новых файлов (без коммита)
    func getChangedFiles() async -> [String] {
        let output = await runGit(["status", "--porcelain"])
        return output.components(separatedBy: .newlines)
            .compactMap { line -> String? in
                guard line.count > 3 else { return nil }
                // Формат: " M path" или "?? path". Берем всё после первых 3 символов
                return String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
    }
}

// Инструменты
struct GitStatusTool: AgentTool {
    let gitService: GitService
    var definition: ToolDefinition {
        ToolDefinition(name: "git_status", description: "Показывает измененные файлы", parameters: [:])
    }
    func execute(arguments: String) async throws -> String {
        return await gitService.getStatus()
    }
}

struct GitDiffTool: AgentTool {
    let gitService: GitService
    var definition: ToolDefinition {
        ToolDefinition(name: "git_diff", description: "Показывает построчный diff изменений", parameters: [:])
    }
    func execute(arguments: String) async throws -> String {
        let diff = await gitService.getDiff()
        return diff.isEmpty ? "Нет изменений" : String(diff.prefix(5000))
    }
}
