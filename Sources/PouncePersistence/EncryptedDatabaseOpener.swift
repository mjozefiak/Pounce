import Foundation

/// Opens an encrypted plugin store with the key from the Keychain, applying the spec's reset policy.
///
/// - Key found: open the store with it. A database that does not open with the key throws (the plugin goes
///   to `failed`); nothing is deleted.
/// - Key definitely missing (`errSecItemNotFound`): the only reset. A new key is stored first; only then an
///   existing database (and the extra files named in `archivedNames`, such as the clipboard's blobs) is
///   archived as `<name>.unreadable-<date>` (kept 30 days), and a new, empty store is created.
/// - Any other Keychain outcome (locked, denied, malformed, unexpected): the store is unavailable, every
///   file stays as it is, and the plugin retries later.
public struct EncryptedDatabaseOpener: Sendable {
    public static let archiveRetention: TimeInterval = 30 * 24 * 60 * 60
    public static let archiveMarker = ".unreadable-"

    public enum Outcome<Store> {
        /// `resetArchive` is the archived database when this open reset the store.
        case opened(Store, resetArchive: URL?)
        case unavailable(KeyStoreError)
    }

    public let directory: URL
    /// The database file name, for example `clipboard.sqlite`.
    public let databaseFileName: String
    /// Files and directories that go with the database and are archived with it (the clipboard's `blobs`).
    public let extraNames: [String]
    public let keyStore: MasterKeyStore

    public init(directory: URL, databaseFileName: String, extraNames: [String] = [], keyStore: MasterKeyStore) {
        self.directory = directory
        self.databaseFileName = databaseFileName
        self.extraNames = extraNames
        self.keyStore = keyStore
    }

    public var databaseURL: URL { directory.appending(path: databaseFileName) }

    /// - Parameter openStore: opens (and creates) the store with the keys.
    public func open<Store>(
        now: Date, fileManager: FileManager = .default, openStore: (MasterKeys) throws -> Store
    ) throws -> Outcome<Store> {
        switch keyStore.lookup() {
        case .found(let keys):
            return .opened(try openStore(keys), resetArchive: nil)
        case .failed(let error):
            return .unavailable(error)
        case .missing:
            let keys: MasterKeys
            do {
                keys = try keyStore.create()
            } catch {
                return .unavailable(error)
            }
            let archive = try archiveExistingStore(now: now, fileManager: fileManager)
            return .opened(try openStore(keys), resetArchive: archive)
        }
    }

    /// Moves an unreadable database (and its journal files and extras) aside. Returns the archived database,
    /// or `nil` when there was none.
    public func archiveExistingStore(now: Date, fileManager: FileManager = .default) throws -> URL? {
        guard fileManager.fileExists(atPath: databaseURL.path) else { return nil }
        let suffix = Self.archiveMarker + Self.stamp(now)
        var archived: URL?
        for name in [
            databaseFileName, databaseFileName + "-wal", databaseFileName + "-shm", databaseFileName + "-journal",
        ]
            + extraNames
        {
            let source = directory.appending(path: name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = directory.appending(path: name + suffix)
            try fileManager.moveItem(at: source, to: target)
            if name == databaseFileName {
                archived = target
            }
        }
        return archived
    }

    /// Deletes archives older than 30 days. Returns how many were deleted.
    @discardableResult
    public func purgeOldArchives(now: Date, fileManager: FileManager = .default) -> Int {
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

    public static func stamp(_ date: Date) -> String { formatter().string(from: date) }
    public static func date(_ stamp: String) -> Date? { formatter().date(from: stamp) }
}
