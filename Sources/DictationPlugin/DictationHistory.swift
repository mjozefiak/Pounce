import CryptoKit
import Foundation
import LintelKit
import LintelPersistence
import Observation
import Synchronization
import os

final class StoreBox: Sendable {
    private let inner = Mutex<DictationStore?>(nil)
    var value: DictationStore? {
        get { inner.withLock { $0 } }
        set { inner.withLock { $0 = newValue } }
    }
}

/// Owns the dictation history for the plugin: opens `dictation.sqlite` with the key from the Keychain, records
/// finished dictations, applies retention and clears or erases everything.
///
/// Only a definitely missing key (`errSecItemNotFound`) may reset the history (the old file is archived as
/// `dictation.sqlite.unreadable-<date>`); any other Keychain error turns the history off with a message and
/// deletes nothing. Dictation itself keeps working either way.
@MainActor @Observable
final class DictationHistory {
    enum Status: Equatable {
        case closed
        case ready
        /// The Keychain key could not be read; nothing was deleted.
        case unavailable(KeyStoreError)
        /// The database could not be opened.
        case failed
    }

    static let service = "com.lintelapp.dictation"
    /// The service name before the app was renamed; the key is copied from it once.
    static let legacyService = "app.pounce.dictation"  // LEGACY-POUNCE
    static let retentionInterval: Duration = .seconds(60 * 60)
    static let vacuumInterval: TimeInterval = 24 * 60 * 60

    private(set) var status = Status.closed
    private(set) var entryCount = 0
    /// Set when this open reset an unreadable history; the archive is kept for 30 days.
    private(set) var resetArchive: URL?

    /// Readable from any thread: the list mode's source searches off the main actor.
    @ObservationIgnored let storeBox = StoreBox()
    var store: DictationStore? {
        get { storeBox.value }
        set { storeBox.value = newValue }
    }
    /// The identity of the open store for note keys (`dictation:<store id>/<row id>`): lowercase hex of the first 8
    /// bytes of the `note-identity` sub-key. Kept in memory only, never written to `dictation.sqlite`; it changes
    /// whenever the Keychain item is recreated (Erase Data, a missing key), so a recreated store never reuses a
    /// key. `nil` while the store is not open.
    @ObservationIgnored let identityBox = Mutex<String?>(nil)
    nonisolated var storeID: String? { identityBox.withLock { $0 } }
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let keychain: any KeychainClient
    @ObservationIgnored private let settings: DictationSettings
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private let changed: @Sendable () -> Void
    @ObservationIgnored private let runsRetentionJob: Bool
    @ObservationIgnored private var retentionTask: Task<Void, Never>?
    @ObservationIgnored private var lastVacuum: Date?

    init(
        directory: URL, keychain: any KeychainClient, settings: DictationSettings, clock: any Clock<Duration>,
        now: @escaping () -> Date = { Date() }, runsRetentionJob: Bool = true, logger: Logger,
        changed: @escaping @Sendable () -> Void = {}
    ) {
        self.runsRetentionJob = runsRetentionJob
        self.directory = directory
        self.keychain = keychain
        self.settings = settings
        self.clock = clock
        self.now = now
        self.logger = logger
        self.changed = changed
    }

    private var keyStore: MasterKeyStore {
        MasterKeyStore(service: Self.service, legacyService: Self.legacyService, keychain: keychain)
    }

    private var opener: EncryptedDatabaseOpener {
        EncryptedDatabaseOpener(
            directory: directory, databaseFileName: DictationStore.fileName,
            keyStore: keyStore)
    }

    var isRecording: Bool { status == .ready && settings.historyEnabled }

    /// Opens the history (when it is switched on) and starts the retention job.
    func open() {
        guard store == nil else { return }
        guard settings.historyEnabled else {
            status = .closed
            return
        }
        let opener = opener
        let directory = directory
        do {
            var identity: String?
            let outcome = try opener.open(now: now()) { keys in
                identity = Self.storeID(of: keys)
                return try DictationStore.open(in: directory, keys: keys)
            }
            switch outcome {
            case .opened(let opened, let archive):
                store = opened
                identityBox.withLock { $0 = identity }
                resetArchive = archive
                status = .ready
                refreshCount()
                startRetention()
            case .unavailable(let error):
                status = .unavailable(error)
            }
        } catch {
            logger.error(
                "The dictation history could not be opened: \(String(describing: type(of: error)), privacy: .public)")
            status = .failed
        }
        opener.purgeOldArchives(now: now())
    }

    func close() {
        retentionTask?.cancel()
        retentionTask = nil
        try? store?.close()
        store = nil
        identityBox.withLock { $0 = nil }
        status = .closed
    }

    /// Lowercase hex of the first 8 bytes of the `note-identity` sub-key.
    static func storeID(of keys: MasterKeys) -> String {
        keys.derived(info: "note-identity").withUnsafeBytes { bytes in
            bytes.prefix(8).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Switching history off or on in Settings.
    func historyEnabledChanged() {
        if settings.historyEnabled {
            open()
        } else {
            close()
        }
    }

    /// Stores a finished dictation. Never throws: a failure is logged without the text.
    func record(_ entry: DictationEntry) {
        guard isRecording, let store else { return }
        let logger = logger
        let changed = changed
        Task.detached(priority: .utility) { [weak self] in
            do {
                try store.insert(entry)
                await self?.refreshCount()
                changed()
            } catch {
                logger.error("A dictation could not be saved: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    func refreshCount() {
        guard let store else { return }
        entryCount = (try? store.count()) ?? 0
    }

    /// "Clear History": every entry goes; the key and the database stay. A history that is not open cannot be
    /// cleared, and says so: the caller must not report success (or go on to remove the kept copies in Notes).
    func clear() throws {
        guard let store else { throw DictationStoreError.closed }
        try store.deleteAll()
        try? store.vacuum()
        refreshCount()
        changed()
    }

    func delete(_ ids: [Int64]) throws {
        try store?.delete(ids)
        refreshCount()
        changed()
    }

    /// "Erase Data": closes the history and removes the Keychain item. The host deletes the folder.
    func erase() throws {
        close()
        try keyStore.delete()
    }

    // MARK: Retention

    var policy: (cutoff: Date, maximum: Int) {
        (now().addingTimeInterval(-Double(settings.retentionDays) * 86_400), settings.maximumEntries)
    }

    /// One pass now: expired and surplus entries go, and a `VACUUM` runs at most once a day.
    @discardableResult
    func applyRetention() -> Int {
        guard let store else { return 0 }
        let (cutoff, maximum) = policy
        let deleted = (try? store.applyRetention(cutoff: cutoff, maximumCount: maximum)) ?? 0
        let current = now()
        if deleted > 0, lastVacuum.map({ current.timeIntervalSince($0) >= Self.vacuumInterval }) ?? true {
            lastVacuum = current
            try? store.vacuum()
        }
        if deleted > 0 {
            logger.info("Retention deleted \(deleted, privacy: .public) dictation entries")
            refreshCount()
            changed()
        }
        return deleted
    }

    private func startRetention() {
        guard runsRetentionJob else { return }
        retentionTask?.cancel()
        let clock = clock
        retentionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                applyRetention()
                opener.purgeOldArchives(now: now())
                do {
                    try await clock.sleep(for: Self.retentionInterval)
                } catch {
                    return
                }
            }
        }
    }
}
