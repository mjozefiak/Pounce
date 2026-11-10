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

    /// Whether `notes.sqlite` exists, without opening it (no Keychain lookup).
    var storeFileExists: Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: NotesStore.fileName).path)
    }

    /// Opens the library only to READ it for a count or a removal, and never in a way that could reset it: the
    /// file must exist and the Keychain item must be found. A missing item (which `open()` would answer with an
    /// archive and a reset), a locked Keychain or a failed open leaves every file alone and answers `nil`.
    func openIfKeyPresent() -> NotesStore? {
        if let store { return store }
        guard storeFileExists else { return nil }
        guard case .found = NotesKeyStore(keychain: keychain).lookup() else { return nil }
        open()
        return store
    }

    /// The store can be read (it may still refuse writes).
    var canRead: Bool { store != nil }

    /// Opens the library once; later calls do nothing while it is open.
    ///
    /// This runs the Keychain lookup, the SQLCipher open and the migration synchronously on the main actor, on
    /// purpose: `MeetingsLibrary.open()` does the same, the open is lazy (the first thing that needs the store),
    /// and the store type is created and used on the main actor by the shell. Moving it off would make `status`
    /// and `store` change under the views that read them. The `open` log line carries the duration.
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
                // Only a successful open may delete anything: a locked Keychain or a failed open keeps every file.
                opener.purgeOldArchives(now: now())
                // The persistent rule: a detached row without user writing and without an open comment is
                // deleted (nothing is open yet, so a leftover from a crash or a quit goes now).
                if !opened.hasNewerSchema {
                    do { try opened.applyRetention(now: now()) } catch {
                        log.error(NotesLogEvent("open", code: (error as? NotesError)?.code ?? "cleanupFailed"))
                    }
                }
            case .unavailable(let error):
                status = .unavailable(error)
                log.error(NotesLogEvent("open", code: NotesError.keyUnavailable.code))
            }
        } catch {
            status = .failed
            let code = (error as? NotesError)?.code ?? "openFailed"
            log.error(NotesLogEvent("open", code: code))
        }
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
