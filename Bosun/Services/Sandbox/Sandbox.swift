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
