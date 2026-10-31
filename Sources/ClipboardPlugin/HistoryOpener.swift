import Foundation
import PounceKit

/// Opens the clipboard history with the key from the Keychain, applying the spec's reset policy.
///
/// - Key found: open `clipboard.sqlite` with it. A database that does not open with the key throws
///   (the plugin goes to `failed`); nothing is deleted.
/// - Key definitely missing (`errSecItemNotFound`): the only reset. A new key is stored first; only
///   then an existing database and its blobs are archived as `clipboard.sqlite.unreadable-<date>` and
///   `blobs.unreadable-<date>` (kept 30 days), and a new, empty database is created.
/// - Any other Keychain outcome (locked, denied, malformed, unexpected): history is unavailable, every
///   file stays as it is, and the plugin retries later.
struct HistoryOpener {
    static let archiveRetention: TimeInterval = 30 * 24 * 60 * 60
    static let archiveMarker = ".unreadable-"

    enum Outcome {
        /// `resetArchive` is the archived database when this open reset the history.
        case opened(ClipStore, resetArchive: URL?)
        case unavailable(KeyStoreError)
    }

    let directory: URL
    let keyStore: KeyStore
    var fileManager: FileManager = .default

    var databaseURL: URL { directory.appending(path: ClipStore.fileName) }

    func open(now: Date) throws -> Outcome {
        switch keyStore.lookup() {
        case .found(let keys):
            return .opened(try ClipStore.open(in: directory, keys: keys, fileManager: fileManager), resetArchive: nil)
        case .failed(let error):
            return .unavailable(error)
        case .missing:
            let keys: ClipKeys
            do {
                keys = try keyStore.create()
            } catch {
                return .unavailable(error)
            }
            let archive = try archiveExistingHistory(now: now)
            return .opened(
                try ClipStore.open(in: directory, keys: keys, fileManager: fileManager), resetArchive: archive)
        }
    }

    /// Moves an unreadable database (and its journal files and blobs) aside. Returns the archived
    /// database, or `nil` when there was none.
    func archiveExistingHistory(now: Date) throws -> URL? {
        guard fileManager.fileExists(atPath: databaseURL.path) else { return nil }
        let suffix = Self.archiveMarker + Self.stamp(now)
        var archived: URL?
        for name in [
            ClipStore.fileName, ClipStore.fileName + "-wal", ClipStore.fileName + "-shm",
            ClipStore.fileName + "-journal", ClipStore.blobsDirectoryName,
        ] {
            let source = directory.appending(path: name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = directory.appending(path: name + suffix)
            try fileManager.moveItem(at: source, to: target)
            if name == ClipStore.fileName {
                archived = target
            }
        }
        return archived
    }

    /// Deletes archives older than 30 days. Returns how many were deleted.
    @discardableResult
    func purgeOldArchives(now: Date) -> Int {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names {
            guard let range = name.range(of: Self.archiveMarker),
                let date = Self.date(String(name[range.upperBound...]))
            else { continue }
            guard now.timeIntervalSince(date) > Self.archiveRetention else { continue }
            if (try? fileManager.removeItem(at: directory.appending(path: name))) != nil {
                removed += 1
            }
        }
        return removed
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }

    static func stamp(_ date: Date) -> String {
        formatter().string(from: date)
    }

    static func date(_ stamp: String) -> Date? {
        formatter().date(from: stamp)
    }
}
