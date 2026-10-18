import Foundation

actor ProjectMap {
    private let rootURL: URL
    private var cachedTree: String?
    
    init(rootURL: URL) {
        self.rootURL = rootURL
    }
    
    /// Возвращает текстовое дерево (из кэша, если есть)
    func getTree() async -> String {
        if let cached = cachedTree { return cached }
        let tree = await buildTree()
        cachedTree = tree
        return tree
    }
    
    /// Принудительно пересобирает дерево
    func refreshTree() async -> String {
        let tree = await buildTree()
        cachedTree = tree
        return tree
    }
    
    private func buildTree() async -> String {
        var result = "\(rootURL.lastPathComponent)/\n"
        let children = await getChildren(of: rootURL)
        result += formatTree(nodes: children, prefix: "")
        return result
    }
    
    private struct Node {
        let url: URL
        let isDirectory: Bool
        let children: [Node]
    }
    
    private func getChildren(of url: URL) async -> [Node] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        
        var nodes: [Node] = []
        for fileURL in contents {
            let name = fileURL.lastPathComponent
            if ExcludedPaths.names.contains(name) { continue }
            if name.hasPrefix(".") { continue }
            
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let children = await getChildren(of: fileURL)
                nodes.append(Node(url: fileURL, isDirectory: true, children: children))
            } else {
                nodes.append(Node(url: fileURL, isDirectory: false, children: []))
            }
        }
        
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }
    
    private func formatTree(nodes: [Node], prefix: String) -> String {
        var result = ""
        for (index, node) in nodes.enumerated() {
            let isLast = index == nodes.count - 1
            let branch = isLast ? "└── " : "├── "
            let name = node.url.lastPathComponent + (node.isDirectory ? "/" : "")
            result += prefix + branch + name + "\n"
            
            if node.isDirectory {
                let newPrefix = prefix + (isLast ? "    " : "│   ")
                result += formatTree(nodes: node.children, prefix: newPrefix)
            }
        }
        return result
    }
}
