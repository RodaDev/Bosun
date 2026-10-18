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
