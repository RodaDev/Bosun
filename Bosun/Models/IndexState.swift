import Foundation

enum IndexStatus: Equatable {
    case notIndexed
    case indexing(progress: String)
    case indexed(date: Date)
    case error(String)
}

struct IndexState: Equatable {
    var status: IndexStatus = .notIndexed
    
    var isIndexing: Bool {
        if case .indexing = status { return true }
        return false
    }
    
    var isReady: Bool {
        if case .indexed = status { return true }
        return false
    }
    
    var progressMessage: String {
        if case .indexing(let msg) = status { return msg }
        return ""
    }
    
    var errorMessage: String? {
        if case .error(let msg) = status { return msg }
        return nil
    }
}
