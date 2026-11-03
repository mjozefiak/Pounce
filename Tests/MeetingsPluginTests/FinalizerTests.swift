import Foundation
import GRDB
import Synchronization
import Testing

@testable import MeetingsPlugin

/// A diarizer without a model. Reads the whole track like the real one does (so the budget and the spool
/// reader are exercised) and answers from a script: the first call is the microphone, the second the system track.
final class ScriptedDiarizer: Diarizer {
    private struct State {
        var script: [Result<[DiarizedSpan], any Error>]
        var calls = 0
        var samples: [Int] = []
        var maximums: [Int] = []
        var releases = 0
    }

    let modelID = "diarization-test"
    private let state: Mutex<State>

    init(_ script: [Result<[DiarizedSpan], any Error>]) { state = Mutex(State(script: script)) }

    var calls: Int { state.withLock { $0.calls } }
    var samples: [Int] { state.withLock { $0.samples } }
    var maximums: [Int] { state.withLock { $0.maximums } }
    var releases: Int { state.withLock { $0.releases } }

    func diarize(_ source: any AudioSampleSource, maximumSamples: Int) async throws -> [DiarizedSpan] {
        state.withLock { $0.maximums.append(maximumSamples) }
        let buffer = try DiarizationAudioBuffer.read(from: source, maximumSamples: maximumSamples)
        let answer = state.withLock { state -> Result<[DiarizedSpan], any Error> in
            state.calls += 1
            state.samples.append(buffer.samples.count)
            return state.script.isEmpty ? .success([]) : state.script.removeFirst()
        }
        return try answer.get()
    }

    func release() async { state.withLock { $0.releases += 1 } }
}

private struct Rig {
    let directory = try! TemporaryDirectory()
    let keys: MeetingKeys
    let store: MeetingsStore
    let spool: SpoolStorage
    let uuid = UUID()
    let meetingID: Int64

    init(mic: [(Int, Int)] = [(0, 4_000)], system: [(Int, Int)] = [(5_000, 9_000)], audioSeconds: Int = 12) throws {
        keys = try testKeys()
        store = try MeetingsStore.open(in: directory.url.appending(path: "meetings"), keys: keys)
        spool = SpoolStorage(pluginDirectory: directory.url.appending(path: "meetings"))
        meetingID = try store.insertMeeting(
            uuid: SpoolStorage.name(of: uuid), startedAt: Date(), speechModelID: "test", status: .processing)
        for (index, window) in mic.enumerated() {
            try store.insertSegment(
                meetingID: meetingID, channel: .mic, startMs: window.0, endMs: window.1, text: "m\(index)")
        }
        for (index, window) in system.enumerated() {
            try store.insertSegment(
                meetingID: meetingID, channel: .system, startMs: window.0, endMs: window.1, text: "s\(index)")
        }
        let pair = try SpoolWriter.createPair(in: spool, meeting: uuid, keys: keys, freeSpace: { _ in .max })
        let audio = [Int16](repeating: 1_000, count: audioSeconds * SpoolFormat.sampleRate)
        try pair.mic.append(audio)
        try pair.mic.close()
        try pair.system.append(audio)
        try pair.system.close()
    }

    func finalizer(
        enabled: Bool = true, folder: URL? = URL(filePath: "/models"), diarizer: ScriptedDiarizer,
        budget: DiarizationBudget = DiarizationBudget(), outcomes: OutcomeLog? = nil
    ) -> MeetingFinalizer {
        MeetingFinalizer(
            store: store, keys: keys, spool: spool, isEnabled: { enabled }, modelFolder: { folder },
            makeDiarizer: { _ in diarizer }, budget: budget,
            onOutcome: { id, outcome in outcomes?.record(id, outcome) })
    }
}

final class OutcomeLog: Sendable {
    private let items = Mutex<[(Int64, DiarizationOutcome)]>([])
    func record(_ id: Int64, _ outcome: DiarizationOutcome) { items.withLock { $0.append((id, outcome)) } }
    var outcomes: [DiarizationOutcome] { items.withLock { $0.map(\.1) } }
}

private func span(_ cluster: String, _ start: Int, _ end: Int) -> DiarizedSpan {
    DiarizedSpan(cluster: cluster, startMs: start, endMs: end)
}

@Suite struct MeetingFinalizerTests {
    @Test func successWritesSpeakersLinksSegmentsAndRecordsTheModel() async throws {
        let rig = try Rig()
        let diarizer = ScriptedDiarizer([.success([span("S1", 0, 4_000)]), .success([span("S1", 5_000, 9_000)])])
        let log = OutcomeLog()
        let outcome = await rig.finalizer(diarizer: diarizer, outcomes: log).run(
            meetingID: rig.meetingID, uuid: rig.uuid)

        #expect(outcome == .diarized(speakers: 2))
        #expect(log.outcomes == [.diarized(speakers: 2)])
        #expect(try rig.store.speakerMode(of: rig.meetingID) == .diarized)
        #expect(try rig.store.diarizationModelID(of: rig.meetingID) == "diarization-test")
        let speakers = try rig.store.speakers(meetingID: rig.meetingID)
        #expect(speakers.map(\.label) == ["Ja", "Mówca 1"])
        #expect(speakers.map(\.isSelf) == [true, false])
        let linked = try rig.store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM meeting_segment WHERE speaker_id IS NOT NULL") ?? 0
        }
        #expect(linked == 2)
        // Each track was diarized on its own, with the whole spool, and the diarizer was released afterwards.
        #expect(diarizer.calls == 2)
        #expect(diarizer.samples == [12 * SpoolFormat.sampleRate, 12 * SpoolFormat.sampleRate])
        #expect(diarizer.releases == 1)
    }

    @Test func aLiveMeetingWithASilentSystemTrackGivesNumberedSpeakersAndNoJa() async throws {
        let rig = try Rig(mic: [(0, 3_000), (4_000, 8_000)], system: [])
        let diarizer = ScriptedDiarizer([.success([span("S1", 0, 3_000), span("S2", 4_000, 8_000)])])
        let outcome = await rig.finalizer(diarizer: diarizer).run(meetingID: rig.meetingID, uuid: rig.uuid)
        #expect(outcome == .diarized(speakers: 2))
        let speakers = try rig.store.speakers(meetingID: rig.meetingID)
        #expect(speakers.map(\.label) == ["Mówca 1", "Mówca 2"])
        #expect(speakers.allSatisfy { !$0.isSelf })
        // The track without segments was not diarized at all.
        #expect(diarizer.calls == 1)
        // "To ja": the user marks the second speaker.
        #expect(try rig.store.markSelf(speakerID: speakers[1].id))
        let after = try rig.store.speakers(meetingID: rig.meetingID)
        #expect(after.map(\.label) == ["Mówca 1", "Ja"])
        #expect(after.map(\.isSelf) == [false, true])
        // Marking the first one moves the flag and renumbers the former Ja.
        #expect(try rig.store.markSelf(speakerID: speakers[0].id))
        let moved = try rig.store.speakers(meetingID: rig.meetingID)
        #expect(moved.map(\.label) == ["Ja", "Mówca 2"])
        #expect(moved.map(\.isSelf) == [true, false])
    }

    @Test func markSelfKeepsANameTheUserChoseAndMarksNotesStale() async throws {
        let rig = try Rig(mic: [(0, 3_000)], system: [])
        _ = await rig.finalizer(diarizer: ScriptedDiarizer([.success([span("S1", 0, 3_000)])])).run(
            meetingID: rig.meetingID, uuid: rig.uuid)
        let speaker = try #require(rig.store.speakers(meetingID: rig.meetingID).first)
        try rig.store.renameSpeaker(speaker.id, label: "Marek")
        try rig.store.setNotes(rig.meetingID, markdown: "notes", status: .ok)
        #expect(try rig.store.markSelf(speakerID: speaker.id))
        let row = try #require(rig.store.speakers(meetingID: rig.meetingID).first)
        #expect(row.label == "Marek" && row.isSelf)
        #expect(try rig.store.notesStatus(of: rig.meetingID) == .stale)
        #expect(try !rig.store.markSelf(speakerID: 9_999))
    }

    @Test func aFailingDiarizerFallsBackToChannelsAndKeepsTheTranscript() async throws {
        let rig = try Rig()
        // The microphone track succeeds, the system track fails twice (one retry): the mic result is dropped.
        let diarizer = ScriptedDiarizer([
            .success([span("S1", 0, 4_000)]), .failure(DiarizationError.failed), .failure(DiarizationError.failed),
        ])
        let outcome = await rig.finalizer(diarizer: diarizer).run(meetingID: rig.meetingID, uuid: rig.uuid)
        #expect(outcome == .fallback(.failed))
        #expect(diarizer.calls == 3)
        #expect(try rig.store.speakerMode(of: rig.meetingID) == .channels)
        #expect(try rig.store.diarizationModelID(of: rig.meetingID) == nil)
        #expect(try rig.store.speakers(meetingID: rig.meetingID).map(\.label) == ["Ja", "Inni"])
        #expect(try rig.store.segmentCount(meetingID: rig.meetingID) == 2)
        #expect(diarizer.releases == 1)
    }

    @Test func aTransientFailureIsRetriedOnceAndThenSucceeds() async throws {
        let rig = try Rig()
        let diarizer = ScriptedDiarizer([
            .failure(DiarizationError.failed), .success([span("S1", 0, 4_000)]), .success([span("S1", 5_000, 9_000)]),
        ])
        let outcome = await rig.finalizer(diarizer: diarizer).run(meetingID: rig.meetingID, uuid: rig.uuid)
        #expect(outcome == .diarized(speakers: 2))
        #expect(diarizer.calls == 3)
        #expect(try rig.store.speakerMode(of: rig.meetingID) == .diarized)
    }

    @Test func aTrackOverTheBudgetIsNotRetried() async throws {
        let rig = try Rig()
        let diarizer = ScriptedDiarizer([])
        let budget = DiarizationBudget(maximumSamplesPerTrack: 5 * SpoolFormat.sampleRate)
        _ = await rig.finalizer(diarizer: diarizer, budget: budget).run(meetingID: rig.meetingID, uuid: rig.uuid)
        #expect(diarizer.maximums.count == 1)
    }

    @Test func aMicrophoneOnlyMeetingThatFallsBackGetsOneNeutralLabelInChannelsMode() async throws {
        let rig = try Rig(mic: [(0, 3_000), (4_000, 8_000)], system: [])
        let diarizer = ScriptedDiarizer([.failure(DiarizationError.failed), .failure(DiarizationError.failed)])
        let outcome = await rig.finalizer(diarizer: diarizer).run(meetingID: rig.meetingID, uuid: rig.uuid)
        #expect(outcome == .fallback(.failed))
        #expect(try rig.store.speakerMode(of: rig.meetingID) == .channels)
        let speakers = try rig.store.speakers(meetingID: rig.meetingID)
        #expect(speakers.map(\.label) == ["Mówca 1"])
        #expect(speakers.map(\.isSelf) == [false])
    }

    @Test func cancellationLeavesTheMeetingAndTheSpoolAlone() async throws {
        let rig = try Rig()
        let diarizer = ScriptedDiarizer([.failure(CancellationError())])
        let log = OutcomeLog()
        let outcome = await rig.finalizer(diarizer: diarizer, outcomes: log).run(
            meetingID: rig.meetingID, uuid: rig.uuid)
        #expect(outcome == .cancelled)
        #expect(log.outcomes == [.cancelled])
        // Nothing was written: no fallback labels, no mode, the spool is still there, the diarizer was released.
        #expect(try rig.store.speakerMode(of: rig.meetingID) == SpeakerMode.none)
        #expect(try rig.store.speakers(meetingID: rig.meetingID).isEmpty)
        #expect(FileManager.default.fileExists(atPath: rig.spool.directory(for: rig.uuid).path))
        #expect(diarizer.calls == 1)  // the system track was not started
        #expect(diarizer.releases == 1)
    }

    @Test func aCancelledTaskIsNotTurnedIntoAFallback() async throws {
        let rig = try Rig()
        let diarizer = ScriptedDiarizer([.success([span("S1", 0, 4_000)]), .success([span("S1", 5_000, 9_000)])])
        let finalizer = rig.finalizer(diarizer: diarizer)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await finalizer.run(meetingID: rig.meetingID, uuid: rig.uuid)
        }
        let outcome = await task.value
        #expect(outcome == .cancelled)
        #expect(try rig.store.speakerMode(of: rig.meetingID) == SpeakerMode.none)
        #expect(try rig.store.speakers(meetingID: rig.meetingID).isEmpty)
        #expect(FileManager.default.fileExists(atPath: rig.spool.directory(for: rig.uuid).path))
    }

    @Test func markSelfIsRefusedInChannelsMode() async throws {
        let rig = try Rig()
        let diarizer = ScriptedDiarizer([.failure(DiarizationError.failed), .failure(DiarizationError.failed)])
        _ = await rig.finalizer(diarizer: diarizer).run(meetingID: rig.meetingID, uuid: rig.uuid)
        #expect(try rig.store.speakerMode(of: rig.meetingID) == .channels)
        let before = try rig.store.speakers(meetingID: rig.meetingID)
        #expect(before.map(\.label) == ["Ja", "Inni"])
        #expect(try !rig.store.markSelf(speakerID: before[1].id))
        #expect(try rig.store.speakers(meetingID: rig.meetingID) == before)
        // Renaming still works.
        try rig.store.renameSpeaker(before[1].id, label: "Zespół")
        #expect(try rig.store.speakers(meetingID: rig.meetingID).map(\.label) == ["Ja", "Zespół"])
    }

    @Test func aFailedSpeakerPlanRollsBackToTheEarlierOne() async throws {
        let rig = try Rig()
        let diarizer = ScriptedDiarizer([.success([span("S1", 0, 4_000)]), .success([span("S1", 5_000, 9_000)])])
        _ = await rig.finalizer(diarizer: diarizer).run(meetingID: rig.meetingID, uuid: rig.uuid)
        let before = try rig.store.speakers(meetingID: rig.meetingID)
        // The last statement of the transaction fails; everything before it must be undone.
        try rig.store.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_mode BEFORE UPDATE OF speaker_mode ON meeting
                    BEGIN SELECT RAISE(ABORT, 'no'); END
                    """)
        }
        #expect(throws: (any Error).self) {
            try rig.store.applySpeakerPlan(
                SpeakerAssigner.channels(
                    segments: [
                        SegmentRef(id: 1, channel: .mic, startMs: 0, endMs: 1),
                        SegmentRef(id: 2, channel: .system, startMs: 0, endMs: 1),
                    ]),
                meetingID: rig.meetingID, diarizationModelID: nil)
        }
        #expect(try rig.store.speakers(meetingID: rig.meetingID) == before)
        #expect(try rig.store.speakerMode(of: rig.meetingID) == .diarized)
        #expect(try rig.store.diarizationModelID(of: rig.meetingID) == "diarization-test")
        let linked = try rig.store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM meeting_segment WHERE speaker_id IS NOT NULL") ?? 0
        }
        #expect(linked == 2)
    }

    @Test func aTrackOverTheBudgetSkipsDiarizationAndFallsBackToChannels() async throws {
        let rig = try Rig()
        let diarizer = ScriptedDiarizer([])
        let budget = DiarizationBudget(maximumSamplesPerTrack: 5 * SpoolFormat.sampleRate)
        let outcome = await rig.finalizer(diarizer: diarizer, budget: budget).run(
            meetingID: rig.meetingID, uuid: rig.uuid)
        #expect(outcome == .fallback(.overBudget))
        #expect(try rig.store.speakerMode(of: rig.meetingID) == .channels)
        #expect(try rig.store.speakers(meetingID: rig.meetingID).map(\.label) == ["Ja", "Inni"])
        #expect(diarizer.maximums == [5 * SpoolFormat.sampleRate])
        #expect(diarizer.releases == 1)
    }

    @Test func aMissingModelFallsBackWithoutCreatingADiarizer() async throws {
        let rig = try Rig()
        let diarizer = ScriptedDiarizer([])
        let outcome = await rig.finalizer(folder: nil, diarizer: diarizer).run(
            meetingID: rig.meetingID, uuid: rig.uuid)
        #expect(outcome == .fallback(.modelMissing))
        #expect(try rig.store.speakerMode(of: rig.meetingID) == .channels)
        #expect(diarizer.calls == 0)
    }

    @Test func anUnreadableSpoolFallsBack() async throws {
        let rig = try Rig()
        try FileManager.default.removeItem(at: rig.spool.file(for: rig.uuid, track: .system))
        let diarizer = ScriptedDiarizer([.success([span("S1", 0, 4_000)])])
        let outcome = await rig.finalizer(diarizer: diarizer).run(meetingID: rig.meetingID, uuid: rig.uuid)
        #expect(outcome == .fallback(.spoolUnavailable))
        #expect(try rig.store.speakerMode(of: rig.meetingID) == .channels)
    }

    @Test func aSpoolEncryptedForAnotherMeetingKeyFallsBack() async throws {
        let rig = try Rig()
        let wrong = MeetingFinalizer(
            store: rig.store, keys: try testKeys(3), spool: rig.spool, isEnabled: { true },
            modelFolder: { URL(filePath: "/models") }, makeDiarizer: { _ in ScriptedDiarizer([]) })
        let outcome = await wrong.run(meetingID: rig.meetingID, uuid: rig.uuid)
        #expect(outcome == .fallback(.spoolUnavailable))
    }

    @Test func diarizationOffGivesModeNoneWithoutTouchingTheModelOrTheSpool() async throws {
        let rig = try Rig()
        let diarizer = ScriptedDiarizer([])
        let outcome = await rig.finalizer(enabled: false, diarizer: diarizer).run(
            meetingID: rig.meetingID, uuid: rig.uuid)
        #expect(outcome == .disabled)
        #expect(try rig.store.speakerMode(of: rig.meetingID) == SpeakerMode.none)
        #expect(try rig.store.speakers(meetingID: rig.meetingID).isEmpty)
        #expect(diarizer.calls == 0 && diarizer.releases == 0)
        // The track stays on the segment as a hint.
        let channels = try rig.store.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT channel FROM meeting_segment ORDER BY channel")
        }
        #expect(channels == ["mic", "system"])
    }

    @Test func aMeetingWithoutSegmentsHasNothingToLabel() async throws {
        let rig = try Rig(mic: [], system: [])
        let diarizer = ScriptedDiarizer([])
        let outcome = await rig.finalizer(diarizer: diarizer).run(meetingID: rig.meetingID, uuid: rig.uuid)
        #expect(outcome == .nothingToLabel)
        #expect(diarizer.calls == 0)
    }

    @Test func runningTwiceStartsFromACleanSlate() async throws {
        let rig = try Rig()
        let script: [Result<[DiarizedSpan], any Error>] = [
            .success([span("S1", 0, 4_000)]), .success([span("S1", 5_000, 9_000)]),
        ]
        _ = await rig.finalizer(diarizer: ScriptedDiarizer(script)).run(meetingID: rig.meetingID, uuid: rig.uuid)
        _ = await rig.finalizer(diarizer: ScriptedDiarizer(script)).run(meetingID: rig.meetingID, uuid: rig.uuid)
        #expect(try rig.store.speakerCount(meetingID: rig.meetingID) == 2)
    }

    // MARK: Through the session hook

    @Test func theHookRunsInsideASessionBeforeTheMeetingIsReadyAndTheSpoolGoesAfterwards() async throws {
        let sessionRig = try SessionRig(texts: [11: "Dzień dobry", 12: "Hello there"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(11, seconds: 3)
        mic.silence(12)
        var system = TrackScript()
        system.silence(6)
        system.say(12, seconds: 3)
        system.silence(7)
        let uuid = UUID()
        let diarizer = ScriptedDiarizer([.success([span("S1", 1_000, 4_000)]), .success([span("S1", 6_000, 9_000)])])
        let finalizer = MeetingFinalizer(
            store: sessionRig.store, keys: sessionRig.keys, spool: sessionRig.spool, isEnabled: { true },
            modelFolder: { URL(filePath: "/models") }, makeDiarizer: { _ in diarizer })
        let statusSeen = Mutex<MeetingStatus?>(nil)
        let spoolSeen = Mutex(false)
        let store = sessionRig.store
        let spool = sessionRig.spool
        let hook = finalizer.hook
        let session = sessionRig.session(
            mic: mic, system: system, uuid: uuid,
            beforeReady: { id, uuid in
                await hook(id, uuid)
                statusSeen.withLock { $0 = try? store.status(of: id) }
                spoolSeen.withLock { $0 = FileManager.default.fileExists(atPath: spool.directory(for: uuid).path) }
            })
        let id = try await session.start()
        sessionRig.mic.push(mic.samples)
        sessionRig.system.push(system.samples)
        sessionRig.mic.end()
        sessionRig.system.end()
        let outcome = await session.finish()

        #expect(outcome.result == .ready)
        #expect(statusSeen.withLock { $0 } == .processing)
        #expect(spoolSeen.withLock { $0 })
        #expect(try store.speakerMode(of: id) == .diarized)
        #expect(try store.speakers(meetingID: id).map(\.label) == ["Ja", "Mówca 1"])
        #expect(try store.status(of: id) == .ready)
        #expect(!FileManager.default.fileExists(atPath: spool.directory(for: uuid).path))
        #expect(diarizer.releases == 1)
    }
}
