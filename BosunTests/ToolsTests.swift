import XCTest
@testable import Bosun

final class ToolsTests: XCTestCase {
    var tempRoot: URL!
    var sandbox: Sandbox!
    var index: SymbolIndex!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        sandbox = Sandbox(rootURL: tempRoot)
        index = SymbolIndex(rootURL: tempRoot)
        
        // Создаем тестовые файлы
        let file1 = tempRoot.appendingPathComponent("App.swift")
        try "struct MyApp {\n    func run() {}\n}\n".write(to: file1, atomically: true, encoding: .utf8)
        
        let file2 = tempRoot.appendingPathComponent("Utils.swift")
        try "class Helper {\n    let x = 1\n}\n".write(to: file2, atomically: true, encoding: .utf8)
        
        let subDir = tempRoot.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "func test() {}".write(to: subDir.appendingPathComponent("Test.swift"), atomically: true, encoding: .utf8)
    }
    
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }
    
    func testListDir() async throws {
        let tool = ListDirTool(sandbox: sandbox)
        let result = try await tool.execute(arguments: #"{"path": "."}"#)
        XCTAssertTrue(result.contains("App.swift"))
        XCTAssertTrue(result.contains("Sub/"))
    }
    
    func testReadFile() async throws {
        let tool = ReadFileTool(sandbox: sandbox)
        let result = try await tool.execute(arguments: #"{"path": "App.swift"}"#)
        XCTAssertTrue(result.contains("1: struct MyApp"))
        XCTAssertTrue(result.contains("2:     func run()"))
    }
    
    func testSearch() async throws {
        let tool = SearchTool(sandbox: sandbox)
        let result = try await tool.execute(arguments: #"{"query": "MyApp"}"#)
        XCTAssertTrue(result.contains("App.swift:1"))
    }
    
    func testSymbolIndexAndFind() async throws {
        try await index.rebuild()
        
        let tool = FindSymbolTool(index: index)
        let result = try await tool.execute(arguments: #"{"name": "MyApp"}"#)
        XCTAssertTrue(result.contains("struct MyApp"))
    }
    
    func testListSymbols() async throws {
        try await index.rebuild()
        
        let tool = ListSymbolsTool(sandbox: sandbox, index: index)
        let result = try await tool.execute(arguments: #"{"path": "App.swift"}"#)
        XCTAssertTrue(result.contains("1: struct MyApp"))
        XCTAssertTrue(result.contains("2: func run"))
    }
}
