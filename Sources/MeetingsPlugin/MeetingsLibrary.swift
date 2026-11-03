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
    @ObservationIgnored private let spoolStorage: SpoolStorage
    @ObservationIgnored private let makeResumer:
        @MainActor (MeetingsStore, MeetingKeys, SpoolStorage) -> (any MeetingResuming)?
    @ObservationIgnored private var recovery: RecoveryJob?
    @ObservationIgnored private var resumer: (any MeetingResuming)?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var activeResumes: Set<Int64> = []
    /// What the recovery pass of the last `open()` did.
    @ObservationIgnored private(set) var lastRecovery: RecoveryReport?

    init(
        directory: URL, keychain: any KeychainClient, settings: MeetingsSettings, clock: any Clock<Duration>,
        now: @escaping () -> Date = { Date() }, spool: any SpoolMaintenance = NoSpoolMaintenance(),
        runsRetentionJob: Bool = true,
        makeResumer: @escaping @MainActor (MeetingsStore, MeetingKeys, SpoolStorage) -> (any MeetingResuming)? = {
            _, _, _ in nil
        }, logger: Logger, changed: @escaping @Sendable () -> Void = {}
    ) {
        spoolStorage = SpoolStorage(pluginDirectory: directory)
        self.makeResumer = makeResumer
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

    /// Opens the library, recovers interrupted meetings and only then starts the retention job.
    func open() {
        guard store == nil else { return }
        let opener = opener
        let directory = directory
        // A definitely missing key is about to be recreated: nothing in the spool can be read with the new one.
        var keyWasMissing = false
        if case .missing = MeetingKeyStore(keychain: keychain).lookup() { keyWasMissing = true }
        var openedKeys: MeetingKeys?
        do {
            let outcome = try opener.open(now: now()) { keys in
                let meetingKeys = MeetingKeys(keys)
                openedKeys = meetingKeys
                return try MeetingsStore.open(in: directory, keys: meetingKeys)
            }
            switch outcome {
            case .opened(let opened, let archive):
                store = opened
                resetArchive = archive
                status = .ready
                if keyWasMissing, spoolStorage.removeAll() > 0 {
                    logger.notice("The Keychain key was recreated; the unreadable audio spools were deleted")
                }
                if let openedKeys {
                    let report = recoverInterruptedMeetings(store: opened, keys: openedKeys)
                    refreshCount()
                    startRetention(after: report)
                } else {
                    refreshCount()
                }
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
        resumeTask?.cancel()
        resumeTask = nil
        activeResumes = []
        recovery = nil
        resumer = nil
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

    /// Crash recovery (spec step 1.7). Runs inside `open()`, before `startRetention(after:)`.
    private func recoverInterruptedMeetings(store: MeetingsStore, keys: MeetingKeys) -> RecoveryReport {
        let resumer = makeResumer(store, keys, spoolStorage)
        self.resumer = resumer
        let job = RecoveryJob(spool: spoolStorage, keys: keys, now: now, logger: logger)
        recovery = job
        let report = job.recover(store: store, canResume: resumer != nil)
        lastRecovery = report
        if report.changedLibrary { changed() }
        if let resumer, !report.toResume.isEmpty { resumeInBackground(report.toResume, with: resumer) }
        return report
    }

    /// Finalizes the `processing` meetings one after the other (the speech model and the memory are shared).
    private func resumeInBackground(_ meetings: [RecoverableMeeting], with resumer: any MeetingResuming) {
        activeResumes.formUnion(meetings.map(\.id))
        resumeTask = Task { [weak self] in
            for meeting in meetings {
                if Task.isCancelled { return }
                _ = await resumer.resume(meeting, events: { _ in })
                self?.activeResumes.remove(meeting.id)
                self?.refreshCount()
                self?.changed()
            }
        }
    }

    /// "Dokończ": finishes an `incomplete` meeting from its spool on demand (the missing speech is
    /// transcribed, speakers are assigned, the meeting becomes `ready`, the spool goes). `nil` when the
    /// library is not open, no speech setup is wired yet, the meeting is not `incomplete` or is already
    /// being finished. Cancel through the handle; whatever was written stays and the meeting stays `incomplete`.
    func finish(meetingID: Int64) -> MeetingFinishHandle? {
        guard let store, let resumer, !activeResumes.contains(meetingID),
            let meeting = try? store.recoverableMeeting(id: meetingID), meeting.status == .incomplete
        else { return nil }
        activeResumes.insert(meetingID)
        let (stream, continuation) = AsyncStream.makeStream(of: ResumeEvent.self, bufferingPolicy: .unbounded)
        let task = Task { [weak self] in
            let outcome = await resumer.resume(meeting, events: { continuation.yield($0) })
            continuation.finish()
            self?.activeResumes.remove(meetingID)
            self?.refreshCount()
            self?.changed()
            return outcome
        }
        return MeetingFinishHandle(events: stream, task: task)
    }

    private func startRetention(after recovery: RecoveryReport) {
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

/// A running "Dokończ": progress events, the final outcome and cancellation.
final class MeetingFinishHandle: Sendable {
    /// Counts only; ends after `.finished`.
    let events: AsyncStream<ResumeEvent>
    private let task: Task<ResumeOutcome, Never>

    init(events: AsyncStream<ResumeEvent>, task: Task<ResumeOutcome, Never>) {
        self.events = events
        self.task = task
    }

    func cancel() { task.cancel() }

    var outcome: ResumeOutcome { get async { await task.value } }
}
