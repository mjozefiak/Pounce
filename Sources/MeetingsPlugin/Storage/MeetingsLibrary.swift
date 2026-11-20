import Foundation
import LintelKit
import LintelPersistence
import Observation
import Synchronization
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
    /// The open store for readers that are not on the main actor (the Notes workspace's `MeetingNoteSource`):
    /// `nil` exactly while `store` is.
    @ObservationIgnored nonisolated let storeBox = Mutex<MeetingsStore?>(nil)
    /// The working keys of the open library, for the session that records into it.
    private(set) var keys: MeetingKeys?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let keychain: any KeychainClient
    @ObservationIgnored private let settings: MeetingsSettings
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private let changed: @Sendable () -> Void
    @ObservationIgnored private let runsRetentionJob: Bool
    @ObservationIgnored let retention: RetentionJob
    @ObservationIgnored let spoolStorage: SpoolStorage
    @ObservationIgnored private let makeResumer:
        @MainActor (MeetingsStore, MeetingKeys, SpoolStorage) -> (any MeetingResuming)?
    @ObservationIgnored private var recovery: RecoveryJob?
    @ObservationIgnored private var resumer: (any MeetingResuming)?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    /// The background open in progress, if any (`openInBackground`).
    /// `close()` does not clear it: the detached database work cannot be cancelled, so a later `open`/`erase`
    /// waits for it (`settleOpens`) and the task removes itself only if it is still the registered one.
    @ObservationIgnored private var openTask: OpenTask?
    @ObservationIgnored private var openSerial = 0
    /// How many background opens were started (tests: a second open must join or wait, not start another).
    @ObservationIgnored private(set) var openLaunches = 0
    /// Reset archive found by an open that `close()` had already discarded; the next applied open reports it.
    @ObservationIgnored private var carriedResetArchive: URL?

    private struct OpenTask {
        let serial: Int
        let generation: Int
        let task: Task<Void, Never>
    }
    /// "Dokończ" runs by meeting id; `close()` cancels them.
    @ObservationIgnored private var finishTasks: [Int64: Task<ResumeOutcome, Never>] = [:]
    /// The meetings a recovery or "Dokończ" pass is working on right now (their rows and spools are in use).
    /// Observed, so the privacy buttons switch off while it is not empty.
    private(set) var activeResumes: Set<Int64> = []
    /// Bumped by every `close()`: a task of an earlier open must not touch the state of a later one.
    @ObservationIgnored private var generation = 0
    /// Meetings a session in this process is recording or finalizing. Survives `close()` and `open()` (a
    /// disable and re-enable of the plugin): recovery, retention and "Dokończ" leave them alone.
    @ObservationIgnored private(set) var liveMeetingIDs: Set<Int64> = []
    /// What the recovery pass of the last `open()` did.
    @ObservationIgnored private(set) var lastRecovery: RecoveryReport?
    /// Told when a meeting becomes `ready` (a recording that ended, a recovered or finished one): the notes
    /// service queues it. Set by the plugin.
    @ObservationIgnored var onMeetingReady: (@MainActor (Int64) -> Void)?
    /// Told at the start of `close()` (and so of `erase()`): the notes service stops its running job.
    @ObservationIgnored var onWillClose: (@MainActor () -> Void)?

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
        retention.protectedMeetingIDs = { [weak self] in self?.protectedMeetingIDs ?? [] }
    }

    /// Meetings that retention must skip: live sessions and those being finished or resumed.
    var protectedMeetingIDs: Set<Int64> { liveMeetingIDs.union(activeResumes) }

    /// A session registers its meeting as soon as the row exists and unregisters it when it ends (ready,
    /// incomplete or failed), so recovery never flips a meeting that is alive in this process.
    /// **`MeetingsPlugin.deactivate` must stop sessions first** (or leave them registered): `close()` does not
    /// end them.
    func registerLive(meetingID: Int64) { liveMeetingIDs.insert(meetingID) }

    func unregisterLive(meetingID: Int64) { liveMeetingIDs.remove(meetingID) }

    /// A meeting became `ready`: the notes may be written (the service decides whether they are wanted).
    func meetingReady(_ id: Int64) { onMeetingReady?(id) }

    private var opener: EncryptedDatabaseOpener {
        EncryptedDatabaseOpener(
            directory: directory, databaseFileName: MeetingsStore.fileName,
            keyStore: MeetingKeyStore(keychain: keychain).master)
    }

    /// Whether a recovery or "Dokończ" pass is transcribing a meeting from its spool right now.
    var isProcessing: Bool { !activeResumes.isEmpty }

    /// Recording needs somewhere to write.
    var canRecord: Bool { status == .ready }

    var policy: RetentionJob.Policy {
        .init(
            retentionDays: settings.retentionDays, orphanAudioDays: settings.orphanAudioDays,
            keptAudioDays: settings.keptAudioDays)
    }

    /// What opening the database produced. Made off the main actor by `performOpen`, applied on it.
    private enum OpenResult: Sendable {
        case opened(MeetingsStore, MeetingKeys, resetArchive: URL?, keyWasMissing: Bool)
        case unavailable(KeyStoreError)
        case failed
    }

    /// The blocking part of opening: the Keychain lookup, the SQLCipher key derivation, the migrations and the
    /// first durable writes, then the purge of old archives. Touches no library state, so it can run anywhere.
    /// The reset policy is the opener's: only `errSecItemNotFound` archives; any other Keychain error is
    /// `.unavailable` and deletes nothing.
    private nonisolated static func performOpen(
        opener: EncryptedDatabaseOpener, directory: URL, now: Date, logger: Logger
    ) -> OpenResult {
        defer { opener.purgeOldArchives(now: now) }
        do {
            var openedKeys: MeetingKeys?
            let (outcome, keyWasMissing) = try opener.openReportingKey(now: now) { keys in
                let meetingKeys = MeetingKeys(keys)
                openedKeys = meetingKeys
                return try MeetingsStore.open(in: directory, keys: meetingKeys)
            }
            switch outcome {
            case .opened(let opened, let archive):
                guard let openedKeys else {
                    try? opened.close()
                    return .failed
                }
                return .opened(opened, openedKeys, resetArchive: archive, keyWasMissing: keyWasMissing)
            case .unavailable(let error):
                return .unavailable(error)
            }
        } catch {
            logger.error(
                "The meetings library could not be opened: \(String(describing: type(of: error)), privacy: .public)")
            return .failed
        }
    }

    /// Publishes the opened state on the main actor, recovers interrupted meetings and only then starts the
    /// retention job.
    private func apply(_ result: OpenResult) {
        switch result {
        case .opened(let opened, let openedKeys, let archive, let keyWasMissing):
            store = opened
            storeBox.withLock { $0 = opened }
            keys = openedKeys
            resetArchive = archive ?? carriedResetArchive
            carriedResetArchive = nil
            status = .ready
            // The key was definitely missing and has been recreated: nothing in the spool can be read with it.
            if keyWasMissing, spoolStorage.removeAll() > 0 {
                logger.notice("The Keychain key was recreated; the unreadable audio spools were deleted")
            }
            NotesRecovery.run(store: opened, logger: logger)
            recoverInterruptedMeetings(store: opened, keys: openedKeys)
            refreshCount()
            startRetention()
        case .unavailable(let error):
            status = .unavailable(error)
        case .failed:
            status = .failed
        }
    }

    /// Opens the library on the calling (main) actor and blocks it for the duration. Kept for callers and tests
    /// that need the result at once; the plugin uses `openInBackground()`.
    func open() {
        guard store == nil, openTask == nil else { return }
        apply(Self.performOpen(opener: opener, directory: directory, now: now(), logger: logger))
    }

    /// Opens the library without blocking the main actor: the database work runs on a background task and the
    /// opened state is published here. Returns when the library is open (or has failed); nothing may use the
    /// library before that. A second call while one is running waits for it. A `close()` meanwhile discards
    /// the result (the store is closed again) and the library stays closed.
    func openInBackground() async {
        // An open of an earlier generation (after `close()`) is waited for, never overlapped: two opens on the
        // same files could both create the key. An open of the current generation is simply joined. A `close()`
        // while this call waits ends it too: the caller asked for the library before the close, not after it.
        let callGeneration = generation
        while let running = openTask {
            await running.task.value
            if generation != callGeneration || running.generation == generation { return }
        }
        guard store == nil else { return }
        let opener = opener
        let directory = directory
        let now = now()
        let logger = logger
        let generation = generation
        openSerial += 1
        openLaunches += 1
        let serial = openSerial
        let task = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.performOpen(opener: opener, directory: directory, now: now, logger: logger)
            }.value
            guard let self else { return }
            if self.openTask?.serial == serial { self.openTask = nil }
            guard self.generation == generation else {
                // Discarded by a `close()`. What the open did to the Keychain and the disk still happened, so
                // the parts that are valid whoever uses the library are kept: a key that had to be recreated
                // makes every old spool unreadable, and a reset archive is reported by the next applied open.
                if case .opened(let opened, _, let archive, let keyWasMissing) = result {
                    try? opened.close()
                    if keyWasMissing, self.spoolStorage.removeAll() > 0 {
                        logger.notice("The Keychain key was recreated; the unreadable audio spools were deleted")
                    }
                    if let archive { self.carriedResetArchive = archive }
                }
                return
            }
            self.apply(result)
        }
        openTask = OpenTask(serial: serial, generation: generation, task: task)
        await task.value
    }

    /// "Erase Data": closes, waits for every background open (also one that `close()` discarded, which would
    /// recreate the key and the folder), then erases.
    func eraseAfterOpens() async throws {
        close()
        await settleOpens()
        try erase()
    }

    /// Waits until no background open is running (also one that `close()` discarded). `erase` needs it: a
    /// stale open would recreate the key and the folder the erase removed.
    func settleOpens() async {
        while let running = openTask { await running.task.value }
    }

    /// Closes the library. Background resumes and "Dokończ" runs are cancelled; they find the store closed if
    /// they write again, so none can finish a meeting after this (and a later `open()` resumes it once, the
    /// meeting being `processing`). Sessions are **not** stopped here: the plugin must stop them before
    /// deactivating, or leave them registered with `registerLive`.
    func close() {
        onWillClose?()
        generation += 1
        retention.stop()
        resumeTask?.cancel()
        resumeTask = nil
        for task in finishTasks.values { task.cancel() }
        finishTasks = [:]
        activeResumes = []
        recovery = nil
        resumer = nil
        try? store?.close()
        store = nil
        storeBox.withLock { $0 = nil }
        keys = nil
        status = .closed
    }

    func refreshCount() {
        guard let store else { return }
        meetingCount = (try? store.meetingCount()) ?? 0
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

    /// How many meetings a retention of `days` would delete now (0 keeps everything, so none).
    func meetingsExpiring(afterDays days: Int) -> Int {
        guard let store, days > 0 else { return 0 }
        let cutoff = RetentionJob.Policy(retentionDays: days, orphanAudioDays: 1).cutoff(now: now())
        guard let cutoff else { return 0 }
        return (try? store.expiredMeetingCount(cutoff: cutoff, excluding: protectedMeetingIDs)) ?? 0
    }

    /// "Erase Data": closes the library, removes the Keychain item and the plugin's folder (the database, its
    /// archives and the spool). The host removes the folder too; both are idempotent.
    ///
    /// Call `close()` and `await settleOpens()` first (the plugin does) so no stale open is still running.
    func erase(fileManager: FileManager = .default) throws {
        close()
        liveMeetingIDs = []
        try MeetingKeyStore(keychain: keychain).delete()
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    /// Crash recovery (spec step 1.7). Runs inside `open()`, before `startRetention(after:)`.
    private func recoverInterruptedMeetings(store: MeetingsStore, keys: MeetingKeys) {
        let resumer = makeResumer(store, keys, spoolStorage)
        self.resumer = resumer
        let job = RecoveryJob(
            spool: spoolStorage, keys: keys, now: now, keepAudio: { [settings] in settings.keepAudio }, logger: logger)
        recovery = job
        let report = job.recover(store: store, canResume: resumer != nil, liveMeetingIDs: liveMeetingIDs)
        lastRecovery = report
        if report.changedLibrary { changed() }
        if let resumer, !report.toResume.isEmpty { resumeInBackground(report.toResume, with: resumer) }
    }

    /// Finalizes the `processing` meetings one after the other (the speech model and the memory are shared).
    private func resumeInBackground(_ meetings: [RecoverableMeeting], with resumer: any MeetingResuming) {
        activeResumes.formUnion(meetings.map(\.id))
        let generation = generation
        resumeTask = Task { [weak self] in
            for meeting in meetings {
                if Task.isCancelled { return }
                let outcome = await resumer.resume(meeting, events: { _ in })
                guard let self, self.generation == generation else { return }
                self.activeResumes.remove(meeting.id)
                self.refreshCount()
                self.changed()
                if outcome == .ready { self.meetingReady(meeting.id) }
            }
        }
    }

    /// "Dokończ": finishes an `incomplete` meeting from its spool on demand (the missing speech is
    /// transcribed, speakers are assigned, the meeting becomes `ready`, the spool goes). `nil` when the
    /// library is not open, no speech setup is wired yet, the meeting is not `incomplete`, is live in this
    /// process or is already being finished. Cancel through the handle; whatever was written stays and the
    /// meeting stays `incomplete`.
    ///
    /// The meeting is `processing` while this runs (claimed in one write), and its spool is touched, so
    /// neither the hourly sweep nor the retention deletes can take it away mid-way. It goes back to
    /// `incomplete` unless the run ended it.
    ///
    /// `acceptGap`: the user agreed to close the meeting although some audio could not be read or
    /// transcribed (an unopenable or empty track, a damaged spool, an unreadable spool). The meeting then
    /// becomes `ready` with the text available and `audio_gap` set (`MeetingsStore.hasAudioGap`). Default
    /// `false`: such a meeting stays `incomplete` and the outcome says why.
    func finish(meetingID: Int64, acceptGap: Bool = false) -> MeetingFinishHandle? {
        guard let store, let resumer, !activeResumes.contains(meetingID), !liveMeetingIDs.contains(meetingID),
            let meeting = try? store.recoverableMeeting(id: meetingID), meeting.status == .incomplete,
            (try? store.claimForFinishing(meetingID)) == true
        else { return nil }
        activeResumes.insert(meetingID)
        if let uuid = meeting.uuid { spoolStorage.touch(meeting: uuid, at: now()) }
        let generation = generation
        let (stream, continuation) = AsyncStream.makeStream(of: ResumeEvent.self, bufferingPolicy: .unbounded)
        let task = Task { [weak self] in
            let outcome = await resumer.resume(meeting, acceptGap: acceptGap, events: { continuation.yield($0) })
            continuation.finish()
            if let self, self.generation == generation {
                try? store.releaseFinishing(meetingID)
                self.activeResumes.remove(meetingID)
                self.finishTasks[meetingID] = nil
                self.refreshCount()
                self.changed()
                if outcome == .ready { self.meetingReady(meetingID) }
            }
            return outcome
        }
        finishTasks[meetingID] = task
        return MeetingFinishHandle(events: stream, task: task)
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
