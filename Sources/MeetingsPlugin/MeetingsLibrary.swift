import Foundation
import Observation
import PounceKit
import PouncePersistence
import os

/// Owns the meetings library for the plugin: opens `meetings.sqlite` with the key from the Keychain, runs
/// the retention job and erases everything.
///
/// Only a definitely missing key (`errSecItemNotFound`) may reset the library (the old file is archived as
/// `meetings.sqlite.unreadable-<date>` and kept 30 days); any other Keychain error turns the library off
/// with a message, recording cannot start (there is nowhere to write) and nothing is deleted.
@MainActor @Observable
final class MeetingsLibrary {
    enum Status: Equatable {
        case closed
        case ready
        /// The Keychain key could not be read; nothing was deleted.
        case unavailable(KeyStoreError)
        /// The database could not be opened.
        case failed
    }

    private(set) var status = Status.closed
    private(set) var meetingCount = 0
    /// Set when this open reset an unreadable library; the archive is kept for 30 days.
    private(set) var resetArchive: URL?
    private(set) var store: MeetingsStore?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let keychain: any KeychainClient
    @ObservationIgnored private let settings: MeetingsSettings
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private let changed: @Sendable () -> Void
    @ObservationIgnored private let runsRetentionJob: Bool
    @ObservationIgnored let retention: RetentionJob

    init(
        directory: URL, keychain: any KeychainClient, settings: MeetingsSettings, clock: any Clock<Duration>,
        now: @escaping () -> Date = { Date() }, spool: any SpoolMaintenance = NoSpoolMaintenance(),
        runsRetentionJob: Bool = true, logger: Logger, changed: @escaping @Sendable () -> Void = {}
    ) {
        self.directory = directory
        self.keychain = keychain
        self.settings = settings
        self.now = now
        self.runsRetentionJob = runsRetentionJob
        self.logger = logger
        self.changed = changed
        retention = RetentionJob(clock: clock, now: now, spool: spool, logger: logger)
    }

    private var opener: EncryptedDatabaseOpener {
        EncryptedDatabaseOpener(
            directory: directory, databaseFileName: MeetingsStore.fileName,
            keyStore: MeetingKeyStore(keychain: keychain).master)
    }

    /// Recording needs somewhere to write.
    var canRecord: Bool { status == .ready }

    var policy: RetentionJob.Policy {
        .init(retentionDays: settings.retentionDays, orphanAudioDays: settings.orphanAudioDays)
    }

    /// Opens the library and starts the retention job.
    func open() {
        guard store == nil else { return }
        let opener = opener
        let directory = directory
        do {
            let outcome = try opener.open(now: now()) { keys in
                try MeetingsStore.open(in: directory, keys: MeetingKeys(keys))
            }
            switch outcome {
            case .opened(let opened, let archive):
                store = opened
                resetArchive = archive
                status = .ready
                refreshCount()
                startRetention()
            case .unavailable(let error):
                status = .unavailable(error)
            }
        } catch {
            logger.error(
                "The meetings library could not be opened: \(String(describing: type(of: error)), privacy: .public)")
            status = .failed
        }
        opener.purgeOldArchives(now: now())
    }

    func close() {
        retention.stop()
        try? store?.close()
        store = nil
        status = .closed
    }

    func refreshCount() {
        guard let store else { return }
        meetingCount = (try? store.meetingCount()) ?? 0
    }

    /// "Clear library": every meeting goes; the key and the database stay.
    func clear() throws {
        guard let store else { return }
        try store.deleteAll()
        try? store.vacuum()
        refreshCount()
        changed()
    }

    /// One retention pass now.
    @discardableResult
    func applyRetention() async -> Int {
        guard let store else { return 0 }
        let deleted = await retention.run(store: store, policy: policy)
        if deleted > 0 {
            refreshCount()
            changed()
        }
        return deleted
    }

    /// "Erase Data": closes the library, removes the Keychain item and the plugin's folder (the database, its
    /// archives and the spool). The host removes the folder too; both are idempotent.
    func erase(fileManager: FileManager = .default) throws {
        close()
        try MeetingKeyStore(keychain: keychain).delete()
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func startRetention() {
        guard runsRetentionJob else { return }
        let opener = opener
        let now = now
        retention.start(
            store: { [weak self] in self?.store },
            policy: { [weak self] in
                self?.policy ?? .init(retentionDays: MeetingsSettings.defaultRetentionDays, orphanAudioDays: 7)
            },
            hourly: { opener.purgeOldArchives(now: now()) },
            changed: { [weak self] in
                self?.refreshCount()
                self?.changed()
            })
    }
}
