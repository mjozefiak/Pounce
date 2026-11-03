import Foundation
import PounceKit
import PouncePersistence

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
    static let archiveRetention = EncryptedDatabaseOpener.archiveRetention
    static let archiveMarker = EncryptedDatabaseOpener.archiveMarker

    enum Outcome {
        /// `resetArchive` is the archived database when this open reset the history.
        case opened(ClipStore, resetArchive: URL?)
        case unavailable(KeyStoreError)
    }

    let directory: URL
    let keyStore: KeyStore
    var fileManager: FileManager = .default

    var databaseURL: URL { directory.appending(path: ClipStore.fileName) }

    private var opener: EncryptedDatabaseOpener {
        EncryptedDatabaseOpener(
            directory: directory, databaseFileName: ClipStore.fileName, extraNames: [ClipStore.blobsDirectoryName],
            keyStore: keyStore.master)
    }

    func open(now: Date) throws -> Outcome {
        let outcome = try opener.open(now: now, fileManager: fileManager) { keys in
            try ClipStore.open(in: directory, keys: ClipKeys(keys), fileManager: fileManager)
        }
        switch outcome {
        case .opened(let store, let archive): return .opened(store, resetArchive: archive)
        case .unavailable(let error): return .unavailable(error)
        }
    }

    /// Moves an unreadable database (and its journal files and blobs) aside. Returns the archived
    /// database, or `nil` when there was none.
    func archiveExistingHistory(now: Date) throws -> URL? {
        try opener.archiveExistingStore(now: now, fileManager: fileManager)
    }

    /// Deletes archives older than 30 days (at activation and then hourly, from `RetentionJob`). Returns how
    /// many were deleted.
    @discardableResult
    func purgeOldArchives(now: Date) -> Int {
        opener.purgeOldArchives(now: now, fileManager: fileManager)
    }

    static func stamp(_ date: Date) -> String { EncryptedDatabaseOpener.stamp(date) }
    static func date(_ stamp: String) -> Date? { EncryptedDatabaseOpener.date(stamp) }
}
