import Darwin
import Foundation
import Synchronization

/// What reading one folder for path mode found.
enum DirectoryListing: Hashable, Sendable {
    /// The folder's entries (at most `DirectoryLister.entryLimit`; `truncated` when there were more).
    case listed([ScannedEntry], truncated: Bool)
    /// The folder is in a TCC-protected place and Lintel has no Full Disk Access: it was not opened.
    case protected
    /// The folder exists but cannot be read (`EPERM`, `EACCES`).
    case denied
    /// The folder does not exist, is not a folder, or its links loop.
    case missing
}

/// Reads one folder, one level deep, straight from disk for path mode (spec: file path search).
///
/// - Index exclusions do not apply: the user typed the path (A4). Hidden entries are reported with
///   `isHidden` so the source can decide.
/// - TCC-protected places are never opened without Full Disk Access (A5): `TCCProtectedLocations.resolve`
///   checks every path on the way, links included, before touching it.
/// - The last folder read is cached by its modification time, so typing a filter does not read the disk
///   again for every key.
/// - `listing(_:fullDiskAccess:)` reads on a serial queue of its own, so a slow volume never holds a Swift
///   concurrency thread; a request cancelled while it waits (the user typed on) is skipped.
final class DirectoryLister: Sendable {
    /// The most entries read from one folder (A8).
    static let entryLimit = 20_000

    private struct Cached {
        let folder: String
        let fullDiskAccess: Bool
        let modified: timespec
        let listing: DirectoryListing
    }

    private let home: String
    private let limit: Int
    private let scanner = BulkScanner(rules: IgnoreRules(includesHidden: true), workerCount: 1)
    private let cache = Mutex<Cached?>(nil)
    private let queue = DispatchQueue(label: "com.lintelapp.files.path-mode", qos: .userInitiated)

    init(home: String, limit: Int = DirectoryLister.entryLimit) {
        self.home = home
        self.limit = max(1, limit)
    }

    /// Lists `folder` on the lister's own queue. Throws `CancellationError` when the task was cancelled
    /// before the read started.
    func listing(_ folder: String, fullDiskAccess: Bool) async throws -> DirectoryListing {
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if cancelled.isSet {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: self.list(folder, fullDiskAccess: fullDiskAccess))
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// Lists `folder` (absolute, standardised) on the calling thread.
    func list(_ folder: String, fullDiskAccess: Bool) -> DirectoryListing {
        let real: String
        switch TCCProtectedLocations.resolve(folder, home: home, fullDiskAccess: fullDiskAccess) {
        case .protected: return .protected
        case .missing: return .missing
        case .resolved(let path): real = path
        }
        var info = stat()
        guard stat(real, &info) == 0 else { return .missing }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .missing }
        let modified = info.st_mtimespec

        if let cached = cache.withLock({ $0 }), cached.folder == real, cached.fullDiskAccess == fullDiskAccess,
            cached.modified.tv_sec == modified.tv_sec, cached.modified.tv_nsec == modified.tv_nsec
        {
            return cached.listing
        }

        let listing: DirectoryListing
        // Read one entry past the limit to know whether the folder was cut short.
        if let entries = scanner.list(real, limit: limit + 1) {
            listing = .listed(Array(entries.prefix(limit)), truncated: entries.count > limit)
        } else {
            listing = .denied
        }
        cache.withLock {
            $0 = Cached(folder: real, fullDiskAccess: fullDiskAccess, modified: modified, listing: listing)
        }
        return listing
    }
}

/// Set once when a waiting read is no longer wanted.
private final class CancellationFlag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
