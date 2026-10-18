#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

mkdir -p Bosun/Models Bosun/Services/Sandbox BosunTests

# 1. ProjectNode
cat > Bosun/Models/ProjectNode.swift <<'SWIFT'
import Foundation

struct ProjectNode: Identifiable, Hashable, Sendable {
    let id: URL
    let name: String
    let isDirectory: Bool
    var children: [ProjectNode]?

    var url: URL { id }
}
SWIFT

# 2. Symbol
cat > Bosun/Models/Symbol.swift <<'SWIFT'
import Foundation

struct Symbol: Identifiable, Hashable, Sendable {
    var id: String { "\(fileURL.path):\(line):\(name)" }
    let name: String
    let kind: String
    let fileURL: URL
    let line: Int
}
SWIFT

# 3. ToolCall
cat > Bosun/Models/ToolCall.swift <<'SWIFT'
import Foundation

struct ToolCall: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let type: String
    let function: Function

    struct Function: Hashable, Codable, Sendable {
        let name: String
        let arguments: String
    }
}
SWIFT

# 4. ToolResult
cat > Bosun/Models/ToolResult.swift <<'SWIFT'
import Foundation

struct ToolResult: Hashable, Sendable {
    let toolCallId: String
    let content: String
    let isError: Bool

    static func error(_ id: String, _ message: String) -> ToolResult {
        ToolResult(toolCallId: id, content: message, isError: true)
    }
}
SWIFT

# 5. AgentEvent
cat > Bosun/Models/AgentEvent.swift <<'SWIFT'
import Foundation

enum AgentEvent: Sendable {
    case textDelta(String)
    case toolCallStarted(ToolCall)
    case toolResult(ToolResult)
    case usage(prompt: Int, completion: Int, cached: Int)
    case done
    case failed(String)
}
SWIFT

# 6. ExcludedPaths
cat > Bosun/Services/Sandbox/ExcludedPaths.swift <<'SWIFT'
import Foundation

enum ExcludedPaths {
    static let names: Set<String> = [
        ".git",
        "DerivedData",
        "Pods",
        ".build",
        "xcuserdata",
        "build",
        ".swiftpm"
    ]
}
SWIFT

# 7. Sandbox
cat > Bosun/Services/Sandbox/Sandbox.swift <<'SWIFT'
import Foundation

enum SandboxError: Error, LocalizedError {
    case outsideRoot(String)
    case excluded(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .outsideRoot(let path): return "Доступ запрещен: путь за пределами проекта (\(path))"
        case .excluded(let path): return "Доступ запрещен: путь исключен из песочницы (\(path))"
        case .notFound(let path): return "Файл или папка не найдены (\(path))"
        }
    }
}

actor Sandbox {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    func resolve(_ path: String) throws -> URL {
        let url: URL
        if path.hasPrefix("/") || path.hasPrefix("~") {
            let expanded = (path as NSString).expandingTildeInPath
            url = URL(fileURLWithPath: expanded)
        } else {
            url = rootURL.appendingPathComponent(path)
        }

        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()

        let rootPath = rootURL.path
        let resolvedPath = resolved.path
        guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") else {
            throw SandboxError.outsideRoot(path)
        }

        let relativePath = resolvedPath.replacingOccurrences(of: rootPath, with: "")
        let components = relativePath.split(separator: "/").map(String.init)
        for comp in components {
            if ExcludedPaths.names.contains(comp) {
                throw SandboxError.excluded(path)
            }
        }

        return resolved
    }

    func validateExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SandboxError.notFound(url.path)
        }
    }
}
SWIFT

# 8. AppEnvironment (перезаписываем полностью, добавляя sandbox)
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
    var projectRoot: URL? {
        didSet {
            if let root = projectRoot {
                sandbox = Sandbox(rootURL: root)
                settings.projectRootPath = root.path
            } else {
                sandbox = nil
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

        if let path = settings.projectRootPath {
            self.projectRoot = URL(fileURLWithPath: path)
        }
    }
}
SWIFT

# 9. SandboxTests
cat > BosunTests/SandboxTests.swift <<'SWIFT'
import XCTest
@testable import Bosun

final class SandboxTests: XCTestCase {
    var tempRoot: URL!
    var sandbox: Sandbox!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        sandbox = Sandbox(rootURL: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        sandbox = nil
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testResolvesValidPath() async throws {
        let file = tempRoot.appendingPathComponent("test.swift")
        FileManager.default.createFile(atPath: file.path, contents: nil)

        let resolved = try await sandbox.resolve("test.swift")
        XCTAssertEqual(resolved.path, file.path)
    }

    func testRejectsPathTraversal() async throws {
        do {
            _ = try await sandbox.resolve("../outside.txt")
            XCTFail("Должна быть ошибка outsideRoot")
        } catch let error as SandboxError {
            if case .outsideRoot = error {} else { XCTFail("Не та ошибка: \(error)") }
        }
    }

    func testRejectsAbsolutePathOutside() async throws {
        do {
            _ = try await sandbox.resolve("/etc/passwd")
            XCTFail("Должна быть ошибка outsideRoot")
        } catch let error as SandboxError {
            if case .outsideRoot = error {} else { XCTFail("Не та ошибка: \(error)") }
        }
    }

    func testRejectsExcludedPath() async throws {
        let gitDir = tempRoot.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)

        do {
            _ = try await sandbox.resolve(".git/config")
            XCTFail("Должна быть ошибка excluded")
        } catch let error as SandboxError {
            if case .excluded = error {} else { XCTFail("Не та ошибка: \(error)") }
        }
    }
    
    func testRejectsSymlinkOutside() async throws {
        let outsideFile = FileManager.default.temporaryDirectory.appendingPathComponent("outside_\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: outsideFile.path, contents: nil)
        
        let symlink = tempRoot.appendingPathComponent("symlink.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideFile)
        
        do {
            _ = try await sandbox.resolve("symlink.txt")
            XCTFail("Должна быть ошибка outsideRoot (через симлинк)")
        } catch let error as SandboxError {
            if case .outsideRoot = error {} else { XCTFail("Не та ошибка: \(error)") }
        }
    }
}
SWIFT

echo "S2a: файлы созданы."
