import Foundation

actor ProjectMap {
    private let rootURL: URL
    private var cachedTree: [ProjectNode]?
    
    init(rootURL: URL) {
        self.rootURL = rootURL
    }
    
    func getTreeNodes() async -> [ProjectNode] {
        if let cached = cachedTree { return cached }
        let nodes = await buildTreeNodes()
        cachedTree = nodes
        return nodes
    }
    
    func refreshTree() async -> [ProjectNode] {
        let nodes = await buildTreeNodes()
        cachedTree = nodes
        return nodes
    }
    
    func getTextTree() async -> String {
        let nodes = await getTreeNodes()
        return formatTextTree(nodes: nodes, prefix: "")
    }
    
    private func buildTreeNodes() async -> [ProjectNode] {
        return await getChildren(of: rootURL)
    }
    
    private func getChildren(of url: URL) async -> [ProjectNode] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        
        var nodes: [ProjectNode] = []
        for fileURL in contents {
            let name = fileURL.lastPathComponent
            if ExcludedPaths.names.contains(name) { continue }
            if name.hasPrefix(".") { continue }
            
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let children = await getChildren(of: fileURL)
                nodes.append(ProjectNode(id: fileURL, name: name, isDirectory: true, children: children))
            } else {
                nodes.append(ProjectNode(id: fileURL, name: name, isDirectory: false, children: nil))
            }
        }
        
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    
    private func formatTextTree(nodes: [ProjectNode], prefix: String) -> String {
        var result = ""
        for (index, node) in nodes.enumerated() {
            let isLast = index == nodes.count - 1
            let branch = isLast ? "└── " : "├── "
            let name = node.name + (node.isDirectory ? "/" : "")
            result += prefix + branch + name + "\n"
            
            if let children = node.children {
                let newPrefix = prefix + (isLast ? "    " : "│   ")
                result += formatTextTree(nodes: children, prefix: newPrefix)
            }
        }
        return result
    }
}
