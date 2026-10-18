import Foundation

struct RunXcodebuildTool: AgentTool {
    let runner: XcodeBuildRunner
    
    var requiresApproval: Bool { true }
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "run_xcodebuild",
            description: "Запускает сборку проекта (xcodebuild). Возвращает только ошибки и предупреждения.",
            parameters: [
                "scheme": ToolParameter(description: "Имя схемы (опционально, если не указано, xcodebuild попробует собрать по умолчанию)")
            ]
        )
    }
    
    struct Args: Decodable {
        let scheme: String?
    }
    
    func prepareApproval(arguments: String) async throws -> ApprovalRequest? {
        let args = try decodeArgs(Args.self, from: arguments)
        let schemeText = args.scheme.map { "схема '\($0)'" } ?? "схема по умолчанию"
        return ApprovalRequest(
            toolName: definition.name,
            path: "Сборка проекта (\(schemeText))",
            oldContent: nil,
            newContent: "Запустить xcodebuild?"
        )
    }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        let result = await runner.run(scheme: args.scheme)
        
        if result.timedOut {
            return "СБОРКА ПРЕРВАНА ПО ТАЙМАУТУ (120 сек)."
        }
        
        if result.exitCode == 0 {
            return "СБОРКА УСПЕШНА."
        }
        
        // Фильтруем лог: оставляем только строки с ошибками и предупреждениями
        let lines = result.output.components(separatedBy: .newlines)
        let importantLines = lines.filter { 
            $0.contains("error:") || $0.contains("warning:") || $0.contains("BUILD FAILED")
        }
        
        if importantLines.isEmpty {
            // Если ошибок не найдено, но код возврата не 0
            return "СБОРКА ПРОВАЛЕНА (код \(result.exitCode)), но лог не содержит 'error:'.\nПоследние 20 строк:\n" + lines.suffix(20).joined(separator: "\n")
        }
        
        return "СБОРКА ПРОВАЛЕНА (код \(result.exitCode)).\nНайдены проблемы:\n" + importantLines.prefix(100).joined(separator: "\n") // Лимит 100 строк ошибок
    }
}
