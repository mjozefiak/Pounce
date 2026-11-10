import Foundation

/// A thread: the comment that started it and the replies, in order. The first comment owns the anchor and the
/// status (a reply repeats them).
struct CommentThread: Identifiable, Equatable, Sendable {
    var id: Int64 { threadID }
    var threadID: Int64
    var comments: [CommentRecord]

    var root: CommentRecord { comments[0] }
    var anchor: CommentAnchor { root.anchor }
    var status: CommentStatus { root.status }
    var isOpen: Bool { root.status == .open }
    var replies: ArraySlice<CommentRecord> { comments.dropFirst() }
}

enum CommentThreads {
    /// Threads in the order they were started (a thread's id grows with every new one).
    static func group(_ records: [CommentRecord]) -> [CommentThread] {
        var order: [Int64] = []
        var byID: [Int64: [CommentRecord]] = [:]
        for record in records {
            if byID[record.threadID] == nil { order.append(record.threadID) }
            byID[record.threadID, default: []].append(record)
        }
        return order.compactMap { id in
            byID[id].map { CommentThread(threadID: id, comments: $0.sorted { $0.id < $1.id }) }
        }
    }
}
