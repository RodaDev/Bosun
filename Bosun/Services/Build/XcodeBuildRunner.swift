import Foundation

struct BuildResult: Sendable {
    let exitCode: Int32
    let output: String
    let timedOut: Bool
}

actor XcodeBuildRunner {
    private let rootURL: URL
    
    init(rootURL: URL) {
        self.rootURL = rootURL
    }
    
    func run(scheme: String? = nil) async -> BuildResult {
        // Находим .xcodeproj или .xcworkspace
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        
        var projectArg: String?
        if let workspace = contents.first(where: { $0.pathExtension == "xcworkspace" }) {
            projectArg = "-workspace \(workspace.lastPathComponent)"
        } else if let project = contents.first(where: { $0.pathExtension == "xcodeproj" }) {
            projectArg = "-project \(project.lastPathComponent)"
        }
        
        guard let project = projectArg else {
            return BuildResult(exitCode: -1, output: "Файл .xcodeproj или .xcworkspace не найден в корне проекта.", timedOut: false)
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        
        var args = project.components(separatedBy: " ")
        if let s = scheme {
            args.append(contentsOf: ["-scheme", s])
        }
        // Собираем для текущей архитектуры Mac (быстрее, чем generic iOS device)
        args.append(contentsOf: ["-destination", "platform=macOS", "build"])
        
        process.arguments = args
        process.currentDirectoryURL = rootURL
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
        } catch {
            return BuildResult(exitCode: -1, output: "Не удалось запустить xcodebuild: \(error.localizedDescription)", timedOut: false)
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
        let timedOut = process.terminationReason == .uncaughtSignal
        
        return BuildResult(exitCode: process.terminationStatus, output: output, timedOut: timedOut)
    }
}
