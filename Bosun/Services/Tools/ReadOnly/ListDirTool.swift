import Foundation

struct ListDirTool: AgentTool {
    let sandbox: Sandbox
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "list_dir",
            description: "Показывает список файлов и папок по указанному пути (относительно корня проекта).",
            parameters: ["path": ToolParameter(description: "Относительный путь к папке (например, 'Sources' или '.')")]
        )
    }
    
    struct Args: Decodable { let path: String }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let url = try await sandbox.resolve(args.path)
        try await sandbox.validateExists(url)
        
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        
        let result = contents.map { fileURL -> String in
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = fileURL.lastPathComponent
            return isDir ? "\(name)/" : name
        }.sorted().joined(separator: "\n")
        
        return result.isEmpty ? "(пустая папка)" : result
    }
}
