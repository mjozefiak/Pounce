import Foundation
import GRDB
import LintelKit
import LintelPersistence
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

final class RecoveryClock: Sendable {
    private let date: Mutex<Date>
    init(_ date: Date) { self.date = Mutex(date) }
    var now: Date { date.withLock { $0 } }
    func set(_ new: Date) { date.withLock { $0 = new } }
}

/// What the finalizer hook saw when it was called.
final class FinalizeLog: Sendable {
    struct Call: Equatable {
        let meetingID: Int64
        let statusDuringCall: MeetingStatus?
        let spoolExisted: Bool
    }

    private let items = Mutex<[Call]>([])
    var calls: [Call] { items.withLock { $0 } }
    func record(_ call: Call) { items.withLock { $0.append(call) } }
}

func eventually(timeout: Duration = .seconds(60), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline, !Task.isCancelled {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Seeds a library the way a crash leaves it (rows plus spool files written by `SpoolWriter` and dropped
/// without a close), then opens a real `MeetingsLibrary` over it. Fakes only: an in-memory keychain, a
/// temporary folder, a scripted engine and voice activity detector.
@MainActor
final class RecoveryRig {
    nonisolated static let started = Date(timeIntervalSince1970: 1_000_000)
    nonisolated static let now = Date(timeIntervalSince1970: 2_000_000)
    nonisolated static let day: TimeInterval = 86_400

    let harness: MeetingsHarness
    let keys: MeetingKeys
    let spool: SpoolStorage
    let engine: ScriptedEngine
    let lease = SpeechEngineLease(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    let finalizations = FinalizeLog()
    let clock = RecoveryClock(RecoveryRig.now)
    private var seedStore: MeetingsStore?
    var seedStoreAccess: MeetingsStore? { seedStore }

    var pluginDirectory: URL { harness.pluginDirectory }

    init(texts: [Int: String] = [:]) throws {
        harness = try MeetingsHarness()
        engine = ScriptedEngine(texts: texts)
        keys = MeetingKeys(try MeetingKeyStore(keychain: harness.keychain).master.create())
        spool = SpoolStorage(pluginDirectory: harness.pluginDirectory)
        seedStore = try MeetingsStore.open(in: harness.pluginDirectory, keys: keys)
    }

    // MARK: Seeding

    /// A track as it was recorded: padded with silence to whole 2 s frames, so every sample is on disk.
    static func int16(_ script: TrackScript) -> [Int16] {
        var samples = script.samples
        let frame = SpoolFormat.samplesPerFrame
        samples += [Float](repeating: 0, count: (frame - samples.count % frame) % frame)
        return samples.map { Int16(max(-1, min(1, $0)) * 32_767) }
    }

    /// The seed is written off the main actor: `SpoolWriter` flushes every frame with `F_FULLFSYNC` and the store
    /// commits with a durable journal, and on the one main thread that every `@MainActor` test shares those waits
    /// starved the library's own `@MainActor` resume task for tens of seconds under disk load (#165).
    @discardableResult
    func seed(
        _ status: MeetingStatus, mic: TrackScript, system: TrackScript? = nil,
        stored: [(AudioChannel, Range<Int>, String)] = [], spoolKeys: MeetingKeys? = nil, writeSpool: Bool = true,
        closeSpool: Bool = false, uuid: UUID = UUID(), audioState: AudioState = .spool
    ) async throws -> (id: Int64, uuid: UUID) {
        let store = try #require(seedStore)
        let spool = spool
        let keys = keys
        let micSamples = Self.int16(mic)
        let systemSamples = system.map(Self.int16)
        let stored = stored.map { (channel: $0.0, samples: $0.1, text: $0.2) }
        return try await Self.write(
            status, store: store, spool: spool, keys: spoolKeys ?? keys, micSamples: micSamples,
            systemSamples: systemSamples, stored: stored, writeSpool: writeSpool, closeSpool: closeSpool, uuid: uuid,
            audioState: audioState)
    }

    private nonisolated static func write(
        _ status: MeetingStatus, store: MeetingsStore, spool: SpoolStorage, keys writerKeys: MeetingKeys,
        micSamples: [Int16], systemSamples: [Int16]?,
        stored: [(channel: AudioChannel, samples: Range<Int>, text: String)],
        writeSpool: Bool, closeSpool: Bool, uuid: UUID, audioState: AudioState
    ) async throws -> (id: Int64, uuid: UUID) {
        let id = try store.insertMeeting(
            uuid: SpoolStorage.name(of: uuid), startedAt: started, speechModelID: "test-model", status: status)
        if audioState == .deleted { try store.setAudioState(id, state: .deleted) }
        for (channel, samples, text) in stored {
            try store.insertSegment(
                meetingID: id, channel: channel, startMs: samples.lowerBound * 1_000 / rate,
                endMs: samples.upperBound * 1_000 / rate, text: text)
        }
        if writeSpool {
            if let systemSamples {
                let pair = try SpoolWriter.createPair(
                    in: spool, meeting: uuid, keys: writerKeys, freeSpace: { _ in .max })
                try pair.mic.append(micSamples)
                try pair.system.append(systemSamples)
                if closeSpool {
                    try pair.mic.close()
                    try pair.system.close()
                }
            } else {
                let writer = try SpoolWriter.create(
                    in: spool, meeting: uuid, track: .mic, keys: writerKeys, freeSpace: { _ in .max })
                try writer.append(micSamples)
                if closeSpool { try writer.close() }
            }
        }
        return (id, uuid)
    }

    func closeSeed() {
        try? seedStore?.close()
        seedStore = nil
    }

    // MARK: Library

    /// The factory `MeetingsLibrary` asks for a resumer. `scripts` are the tracks' speech, in the order the
    /// resumer scans them: system first, then the microphone (each scan gets a fresh detector).
    func resumerFactory(
        mic: TrackScript, system: TrackScript? = nil, haveModel: Bool = true, keepAudio: Bool = false
    ) -> @MainActor (MeetingsStore, MeetingKeys, SpoolStorage) -> (any MeetingResuming)? {
        let spans = (system.map { [$0.spans] } ?? []) + [mic.spans]
        let counter = Mutex(0)
        let engine = engine
        let lease = lease
        let log = finalizations
        let folder = harness.directory.url.appending(path: "model")
        return { store, keys, spool in
            MeetingResumer(
                store: store, keys: keys, spool: spool,
                makeVAD: {
                    let index = counter.withLock { value -> Int in
                        defer { value += 1 }
                        return value
                    }
                    return ScriptedVAD(spans[index % spans.count])
                },
                speech: { haveModel ? ResumeSpeech(engine: engine, modelID: "test-model", folder: folder) : nil },
                lease: lease, keepWarm: { .seconds(600) },
                finalize: { id, uuid in
                    let status = try? store.status(of: id)
                    log.record(
                        .init(
                            meetingID: id, statusDuringCall: status,
                            spoolExisted: FileManager.default.fileExists(atPath: spool.directory(for: uuid).path)))
                },
                now: { RecoveryRig.now }, keepAudio: { keepAudio })
        }
    }

    func library(
        retention: Bool = false, maintenance: (any SpoolMaintenance)? = nil,
        resumer: @escaping @MainActor (MeetingsStore, MeetingKeys, SpoolStorage) -> (any MeetingResuming)? = {
            _, _, _ in
            nil
        }
    ) -> MeetingsLibrary {
        closeSeed()
        let clock = clock
        return MeetingsLibrary(
            directory: pluginDirectory, keychain: harness.keychain, settings: harness.meetingsSettings,
            clock: ContinuousClock(), now: { clock.now },
            spool: maintenance ?? SpoolStorage(pluginDirectory: pluginDirectory), runsRetentionJob: retention,
            makeResumer: resumer, logger: harness.context.logger)
    }

    // MARK: Disk

    func spoolExists(_ uuid: UUID) -> Bool { FileManager.default.fileExists(atPath: spool.directory(for: uuid).path) }

    func modificationDate(_ uuid: UUID) throws -> Date {
        try #require(
            try spool.directory(for: uuid).resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate)
    }

    /// Makes the spool look as if it was last written `date`.
    func age(_ uuid: UUID, to date: Date) throws {
        let directory = spool.directory(for: uuid)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in files + [directory] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    func rows(_ library: MeetingsLibrary, _ id: Int64) throws -> [SegmentRow] {
        let store = try #require(library.store)
        return try store.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT channel, start_ms, end_ms, text, speaker_id FROM meeting_segment
                    WHERE meeting_id = ? ORDER BY start_ms, id
                    """, arguments: [id]
            ).map {
                SegmentRow(
                    channel: $0["channel"], startMs: $0["start_ms"], endMs: $0["end_ms"], text: $0["text"],
                    speakerID: $0["speaker_id"])
            }
        }
    }
}

/// Utterances at fixed places: `shape(...)` builds a track from (silence, say) steps.
extension TrackScript {
    static func build(_ steps: [(silence: Double, code: Int?, seconds: Double)], tail: Double = 0) -> TrackScript {
        var script = TrackScript()
        for step in steps {
            script.silence(step.silence)
            if let code = step.code { script.say(code, seconds: step.seconds) }
        }
        script.silence(tail)
        return script
    }
}
