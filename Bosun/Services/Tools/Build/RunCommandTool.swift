import Foundation

struct RunCommandTool: AgentTool {
    let sandbox: Sandbox
    
    var requiresApproval: Bool { true }
    
    var definition: ToolDefinition {
        ToolDefinition(
            name: "run_command",
            description: "Выполняет команду в терминале (например, 'swift test', 'npm run build'). Требует подтверждения.",
            parameters: [
                "executable": ToolParameter(description: "Имя программы (например, 'swift', 'npm', 'git')"),
                "arguments": ToolParameter(type: "array", description: "Массив строк-аргументов (например, [\"test\", \"--verbose\"])")
            ]
        )
    }
    
    struct Args: Decodable {
        let executable: String
        let arguments: [String]
    }
    
    // Показываем команду в окне подтверждения
    func prepareApproval(arguments: String) async throws -> ApprovalRequest? {
        let args = try decodeArgs(Args.self, from: arguments)
        let cmdString = "\(args.executable) \(args.arguments.joined(separator: " "))"
        return ApprovalRequest(
            toolName: definition.name,
            path: "Запуск в терминале",
            oldContent: nil,
            newContent: cmdString
        )
    }
    
    func execute(arguments: String) async throws -> String {
        let args = try decodeArgs(Args.self, from: arguments)
        
        // Проверяем, что executable не содержит путей (защита от /bin/rm -rf /)
        guard !args.executable.contains("/") else {
            throw NSError(domain: "Command", code: 0, userInfo: [NSLocalizedDescriptionKey: "Запрещено указывать полный путь к исполняемому файлу. Используй имя программы (например, 'swift')."])
        }
        
        let root = await sandbox.rootURL
        
        let process = Process()
        // Ищем программу в PATH
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [args.executable] + args.arguments
        process.currentDirectoryURL = root
        
        // Подхватываем переменные окружения (чтобы работал brew, node, python)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
        } catch {
            throw NSError(domain: "Command", code: 0, userInfo: [NSLocalizedDescriptionKey: "Не удалось запустить '\(args.executable)': \(error.localizedDescription)"])
        }
        
        // Таймаут 120 секунд
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            if process.isRunning {
                process.terminate()
            }
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutTask.cancel()
        
        let output = String(data: data, encoding: .utf8) ?? ""
        
        // Ограничиваем вывод (чтобы не забивать контекст)
        let lines = output.components(separatedBy: .newlines)
        let truncated = lines.suffix(100).joined(separator: "\n")
        
        var result = "Код выхода: \(process.terminationStatus)\n"
        if process.terminationReason == .uncaughtSignal {
            result += "Процесс был принудительно завершен по таймауту (120 сек).\n"
        }
        
        if process.terminationStatus == 0 {
            result += "Команда выполнена успешно.\n"
        } else {
            result += "Команда завершилась с ошибкой.\n"
        }
        
        result += "\nЛог (последние 100 строк):\n\(truncated)"
        return result
    }
}
