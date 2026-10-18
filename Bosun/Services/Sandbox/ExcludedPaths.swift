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
