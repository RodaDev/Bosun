#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

mkdir -p Bosun/Services/Build
mkdir -p Bosun/Services/Tools/Build

# 1. XcodeBuildRunner
cat > Bosun/Services/Build/XcodeBuildRunner.swift <<'SWIFT'
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
SWIFT

# 2. RunXcodebuildTool
cat > Bosun/Services/Tools/Build/RunXcodebuildTool.swift <<'SWIFT'
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
SWIFT

# 3. Обновляем AppEnvironment
cat > Bosun/App/AppEnvironment.swift <<'SWIFT'
import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    let settings: SettingsStore
    let keychain: KeychainStore
    let openRouter: OpenRouterClient
    let chatVM: ChatViewModel
    let modelPickerVM: ModelPickerViewModel
    let settingsVM: SettingsViewModel

    var sandbox: Sandbox?
    var symbolIndex: SymbolIndex?
    var projectMap: ProjectMap?
    var toolRuntime: ToolRuntime?
    
    var projectRoot: URL? {
        didSet {
            if let root = projectRoot {
                let box = Sandbox(rootURL: root)
                let idx = SymbolIndex(rootURL: root)
                let map = ProjectMap(rootURL: root)
                let runner = XcodeBuildRunner(rootURL: root)
                
                self.sandbox = box
                self.symbolIndex = idx
                self.projectMap = map
                
                let tools: [AgentTool] = [
                    ListDirTool(sandbox: box),
                    ReadFileTool(sandbox: box),
                    SearchTool(sandbox: box),
                    FindSymbolTool(index: idx),
                    ListSymbolsTool(sandbox: box, index: idx),
                    WriteFileTool(sandbox: box),
                    EditFileTool(sandbox: box),
                    RunXcodebuildTool(runner: runner)
                ]
                self.toolRuntime = ToolRuntime(registry: ToolRegistry(tools: tools))
                settings.projectRootPath = root.path
                
                Task { try? await idx.rebuild() }
            } else {
                sandbox = nil
                symbolIndex = nil
                projectMap = nil
                toolRuntime = nil
                settings.projectRootPath = nil
            }
        }
    }

    init() {
        let settings = SettingsStore()
        let keychain = KeychainStore()
        let transport = URLSessionTransport()
        let client = OpenRouterClient(transport: transport, keychain: keychain)

        self.settings = settings
        self.keychain = keychain
        self.openRouter = client
        self.chatVM = ChatViewModel(settings: settings, keychain: keychain, client: client)
        self.modelPickerVM = ModelPickerViewModel(client: client)
        self.settingsVM = SettingsViewModel(settings: settings, keychain: keychain)

        if self.keychain.loadAPIKey() == nil {
            self.settings.hasAPIKey = false
        }

        if let path = settings.projectRootPath {
            self.projectRoot = URL(fileURLWithPath: path)
        }
    }
}
SWIFT

echo "S5: XcodebuildRunner готов."
