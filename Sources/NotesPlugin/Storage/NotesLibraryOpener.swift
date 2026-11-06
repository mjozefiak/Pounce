import Foundation
import LintelKit
import LintelPersistence

/// Owns `notes.sqlite` for the plugin and opens it LAZILY: nothing here runs on `activate()`, in a manifest read
/// or in a settings pane. The first thing that needs the store calls `open()`.
///
/// Only a definitely missing key (`errSecItemNotFound`) may reset the library (the old file is archived as
/// `notes.sqlite.unreadable-<date>` and kept 30 days). Any other Keychain error disables editing, commenting
/// and new notes, deletes nothing, and the sources stay listed read-only.
@MainActor
final class NotesLibraryOpener {
    enum Status: Equatable {
        case closed
        case ready
        /// The database is from a newer Lintel: readable, never written, nothing migrated.
        case readOnlySchemaNewer
        /// The Keychain key could not be read; nothing was deleted.
        case unavailable(KeyStoreError)
        /// The database could not be opened.
        case failed
    }

    private(set) var status = Status.closed
    private(set) var store: NotesStore?
    /// Set when this open reset an unreadable library; the archive is kept for 30 days.
    private(set) var resetArchive: URL?

    private let directory: URL
    private let keychain: any KeychainClient
    private let settings: NotesSettings
    private let now: @Sendable () -> Date
    private let log: any NotesLogging

    init(
        directory: URL, keychain: any KeychainClient, settings: NotesSettings,
        now: @escaping @Sendable () -> Date = { Date() }, log: any NotesLogging = OSNotesLog()
    ) {
        self.directory = directory
        self.keychain = keychain
        self.settings = settings
        self.now = now
        self.log = log
    }

    private var encryptedOpener: EncryptedDatabaseOpener {
        EncryptedDatabaseOpener(
            directory: directory, databaseFileName: NotesStore.fileName,
            keyStore: NotesKeyStore(keychain: keychain).master)
    }

    /// Editing, comments and new notes are allowed: the store is open, current and the hidden read-only key is off.
    var canEdit: Bool { status == .ready && !settings.readOnly }

    /// The store can be read (it may still refuse writes).
    var canRead: Bool { store != nil }

    /// Opens the library once; later calls do nothing while it is open.
    func open() {
        guard store == nil else { return }
        let started = ContinuousClock.now
        let opener = encryptedOpener
        let directory = directory
        let settings = settings
        do {
            let outcome = try opener.open(now: now()) { keys in
                try NotesStore.open(
                    in: directory, keys: NotesKeys(keys), writeBlock: { settings.readOnly ? NotesError.readOnly : nil })
            }
            switch outcome {
            case .opened(let opened, let archive):
                store = opened
                resetArchive = archive
                status = opened.hasNewerSchema ? .readOnlySchemaNewer : .ready
                if opened.hasNewerSchema { log.error(NotesLogEvent("open", code: NotesError.schemaNewer.code)) }
                if archive != nil { log.notice(NotesLogEvent("reset")) }
                log.notice(NotesLogEvent("open", durationMs: Self.milliseconds(since: started)))
            case .unavailable(let error):
                status = .unavailable(error)
                log.error(NotesLogEvent("open", code: NotesError.keyUnavailable.code))
            }
        } catch {
            status = .failed
            log.error(NotesLogEvent("open", code: "openFailed"))
        }
        opener.purgeOldArchives(now: now())
    }

    func close() {
        try? store?.close()
        store = nil
        status = .closed
    }

    /// "Erase Data": closes the store, removes the Keychain item and `Plugins/notes/`. Never touches the sources.
    /// It does not open the store, so it also works while the Keychain is locked as far as the folder goes.
    func erase(fileManager: FileManager = .default) throws {
        close()
        resetArchive = nil
        try NotesKeyStore(keychain: keychain).delete()
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        log.notice(NotesLogEvent("erase"))
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let parts = (ContinuousClock.now - start).components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
