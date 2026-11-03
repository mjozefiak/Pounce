import Foundation
import GRDB
import Synchronization
import Testing

@testable import MeetingsPlugin

private let micOnly: TrackScript? = nil

@Suite struct MeetingSessionTests {
    // MARK: Transcripts

    @Test func polishEnglishAndMixedSegmentsLandInOrderOnTheSharedTimeline() async throws {
        let rig = try SessionRig(texts: [
            11: "Dzień dobry, zaczynamy spotkanie", 12: "Let's review the roadmap", 13: "Mamy deadline w piątek, ok?",
            14: "Yes, the deadline is fine", 15: "Przejdźmy do next steps",
        ])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(11, seconds: 3)
        mic.silence(11)
        mic.say(13, seconds: 3)
        mic.silence(8)
        mic.say(15, seconds: 2)
        mic.silence(2)
        var system = TrackScript()
        system.silence(5)
        system.say(12, seconds: 4)
        system.silence(10)
        system.say(14, seconds: 3)
        system.silence(9)
        let session = rig.session(mic: mic, system: system)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.system.push(system.samples)
        rig.mic.end()
        rig.system.end()
        let outcome = await session.finish()
        await log.drain()

        #expect(outcome.result == .ready)
        #expect(outcome.segmentCount == 5)
        #expect(outcome.echoesDropped == 0)
        let rows = try rig.rows(id)
        #expect(
            rows.map(\.text) == [
                "Dzień dobry, zaczynamy spotkanie", "Let's review the roadmap", "Mamy deadline w piątek, ok?",
                "Yes, the deadline is fine", "Przejdźmy do next steps",
            ])
        #expect(rows.map(\.channel) == ["mic", "system", "mic", "system", "mic"])
        #expect(rows.first?.startMs == 1_000)
        #expect(rows.first?.endMs == 4_000)
        #expect(rows.allSatisfy { $0.speakerID == nil })
        #expect(Set(rows.map(\.text)).count == rows.count)
    }

    @Test func aMeetingEndsReadyWithItsSpoolDeletedAndAudioMarkedDeleted() async throws {
        let rig = try SessionRig(texts: [11: "Hello"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(11, seconds: 2)
        mic.silence(14)
        let uuid = UUID()
        let session = rig.session(mic: mic, system: nil, uuid: uuid, withSystem: false)
        let id = try await session.start()
        #expect(FileManager.default.fileExists(atPath: rig.spool.file(for: uuid, track: .mic).path))
        #expect(try rig.store.status(of: id) == .recording)
        rig.mic.push(mic.samples)
        rig.mic.end()
        let outcome = await session.finish()
        #expect(outcome.result == .ready)
        #expect(try rig.store.status(of: id) == .ready)
        #expect(try rig.store.audioState(of: id) == .deleted)
        #expect(!FileManager.default.fileExists(atPath: rig.spool.directory(for: uuid).path))
        #expect(await session.state == .ready)
    }

    // MARK: Echo

    @Test func theMicrophoneCopyOfWhatTheSpeakersPlayedIsDroppedOnce() async throws {
        let rig = try SessionRig(texts: [21: "Welcome everyone to the weekly sync", 22: "Dzięki, mam pytanie"])
        var system = TrackScript()
        system.silence(1)
        system.say(21, seconds: 3)
        system.silence(16)
        var mic = TrackScript()
        mic.silence(1.2)
        mic.say(21, seconds: 3)
        mic.silence(1)
        mic.say(22, seconds: 2)
        mic.silence(12)
        let session = rig.session(mic: mic, system: system)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.system.push(system.samples)
        rig.mic.end()
        rig.system.end()
        let outcome = await session.finish()
        #expect(outcome.echoesDropped == 1)
        let rows = try rig.rows(id)
        #expect(rows.map(\.text) == ["Welcome everyone to the weekly sync", "Dzięki, mam pytanie"])
        #expect(rows.map(\.channel) == ["system", "mic"])
    }

    // MARK: Interruption

    @Test func segmentsAreInTheDatabaseWhileTheMeetingStillRuns() async throws {
        let rig = try SessionRig(texts: [31: "First thing"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(31, seconds: 2)
        mic.silence(3)
        let uuid = UUID()
        let session = rig.session(mic: mic, system: nil, uuid: uuid, withSystem: false)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        #expect(await log.wait { if case .segmentSaved = $0 { true } else { false } })
        // The app dies here: the text is already stored and the meeting is still marked as being recorded.
        #expect(try rig.rows(id).map(\.text) == ["First thing"])
        #expect(try rig.store.status(of: id) == .recording)
        #expect(FileManager.default.fileExists(atPath: rig.spool.file(for: uuid, track: .mic).path))
        _ = await session.finish()
    }

    @Test func disablingThePluginMidMeetingFinishesItWithoutLosingTheTextBeingSpoken() async throws {
        let rig = try SessionRig(texts: [41: "Done sentence", 42: "Still talking when the plugin was switched off"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(41, seconds: 2)
        mic.silence(1)
        mic.say(42, seconds: 3, closed: false)
        let session = rig.session(mic: mic, system: nil, withSystem: false)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        #expect(await log.wait { if case .segmentSaved = $0 { true } else { false } })
        let outcome = await session.finish()
        #expect(outcome.result == .ready)
        #expect(try rig.rows(id).map(\.text) == ["Done sentence", "Still talking when the plugin was switched off"])
        #expect(rig.mic.stops == 1)
        // A second call (the user pressing Stop as well) gets the same result.
        #expect(await session.finish() == outcome)
    }

    // MARK: Discarding

    @Test func aShortSilentRecordingLeavesNoRowAndNoSpool() async throws {
        let rig = try SessionRig()
        var mic = TrackScript()
        mic.silence(5)
        let uuid = UUID()
        let session = rig.session(mic: mic, system: nil, uuid: uuid, withSystem: false)
        let log = SessionEventLog(session)
        try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        let outcome = await session.finish()
        await log.drain()
        #expect(outcome.result == .discarded)
        #expect(outcome.meetingID == nil)
        #expect(try rig.store.meetingCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: rig.spool.directory(for: uuid).path))
        #expect(log.contains { $0 == .nothingHeard })
        #expect(await session.state == .idle)
        #expect(!rig.gate.isTaken)
    }

    @Test func aLongSilentRecordingIsKeptWithoutSegments() async throws {
        let rig = try SessionRig()
        var mic = TrackScript()
        mic.silence(20)
        let session = rig.session(mic: mic, system: nil, withSystem: false)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        let outcome = await session.finish()
        #expect(outcome.result == .ready)
        #expect(try rig.store.status(of: id) == .ready)
        #expect(try rig.store.segmentCount(meetingID: id) == 0)
    }

    // MARK: Tracks

    @Test func losingTheMicrophoneContinuesWithTheSystemTrack() async throws {
        let rig = try SessionRig(texts: [51: "From the call", 52: "Mic before it died"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(52, seconds: 2)
        var system = TrackScript()
        system.silence(6)
        system.say(51, seconds: 3)
        system.silence(10)
        let session = rig.session(mic: mic, system: system)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        #expect(await log.wait { $0 == .trackLost(.mic) })
        #expect(await session.state == .recording)
        rig.system.push(system.samples)
        let outcome = await session.finish()
        #expect(outcome.result == .ready)
        #expect(try rig.rows(id).map(\.text) == ["Mic before it died", "From the call"])
    }

    @Test func losingTheSystemTrackContinuesWithTheMicrophone() async throws {
        let rig = try SessionRig(texts: [61: "Only me now"])
        var mic = TrackScript()
        mic.silence(8)
        mic.say(61, seconds: 2)
        mic.silence(8)
        var system = TrackScript()
        system.silence(2)
        let session = rig.session(mic: mic, system: system)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.system.push(system.samples)
        rig.system.end()
        #expect(await log.wait { $0 == .trackLost(.system) })
        rig.mic.push(mic.samples)
        let outcome = await session.finish()
        #expect(outcome.result == .ready)
        #expect(try rig.rows(id).map(\.text) == ["Only me now"])
    }

    @Test func aTrackThatCannotStartIsReportedAndTheOtherOneRecords() async throws {
        let rig = try SessionRig(texts: [71: "Mic works"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(71, seconds: 2)
        mic.silence(14)
        let broken = ControlledInput(failStart: true)
        let session = rig.session(mic: mic, system: nil, systemInput: broken)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        let outcome = await session.finish()
        #expect(outcome.result == .ready)
        #expect(log.contains { $0 == .trackUnavailable(.system) })
        #expect(try rig.rows(id).map(\.text) == ["Mic works"])
    }

    @Test func whenNoTrackStartsNothingIsLeftBehind() async throws {
        let rig = try SessionRig()
        let uuid = UUID()
        let session = rig.session(
            mic: TrackScript(), system: nil, micInput: ControlledInput(failStart: true), uuid: uuid, withSystem: false)
        await #expect(throws: MeetingSessionError.noAudioInput) { try await session.start() }
        #expect(try rig.store.meetingCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: rig.spool.directory(for: uuid).path))
        #expect(!rig.gate.isTaken)
        #expect(!rig.sleepAssertion.isHeld)
        #expect(rig.sleepAssertion.holds == rig.sleepAssertion.releases)
    }

    // MARK: Limits

    @Test func tooLittleFreeSpaceRefusesToStartWithoutARow() async throws {
        let rig = try SessionRig()
        let session = rig.session(
            mic: TrackScript(), system: nil, freeSpace: { _ in 1_000_000 }, withSystem: false)
        await #expect(throws: SpoolError.self) { try await session.start() }
        #expect(try rig.store.meetingCount() == 0)
        #expect(!rig.gate.isTaken)
        #expect(rig.sleepAssertion.holds == 0)
    }

    @Test func runningLowOnSpaceMidMeetingEndsItGracefullyWithTheTranscriptSaved() async throws {
        let rig = try SessionRig(texts: [81: "Saved before the disk filled up"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(81, seconds: 2)
        mic.silence(12)
        let reads = Mutex(0)
        let session = rig.session(
            mic: mic, system: nil,
            freeSpace: { _ in
                // The start check reads it once per track; later reads see a nearly full disk.
                reads.withLock { reads in
                    reads += 1
                    return reads <= 1 ? Int64.max : 10_000_000
                }
            }, withSystem: false)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        #expect(await log.wait { $0 == .lowDisk })
        let outcome = await session.finish()
        await log.drain()
        #expect(outcome.result == .ready)
        #expect(try rig.rows(id).map(\.text) == ["Saved before the disk filled up"])
        #expect(!rig.sleepAssertion.isHeld)
    }

    @Test func theTimeLimitCountsDownAndEndsTheMeetingByItself() async throws {
        let rig = try SessionRig(texts: [91: "Long meeting"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(91, seconds: 2)
        mic.silence(7)
        var limits = rig.shortLimits
        limits.maximumDuration = .seconds(10)
        limits.warningBefore = .seconds(4)
        limits.discardBelow = .seconds(1)
        let session = rig.session(mic: mic, system: nil, limits: limits, withSystem: false)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        #expect(await log.wait { if case .finished = $0 { true } else { false } })
        let events = log.all
        let countdown = events.compactMap { event -> Int? in
            if case .limitApproaching(let left) = event { left } else { nil }
        }
        // The warning starts 4 s before the 10 s limit and counts every second down to the limit.
        #expect(countdown == [4, 3, 2, 1, 0])
        #expect(events.filter { $0 == .limitReached }.count == 1)
        #expect(try rig.store.status(of: id) == .ready)
        #expect(try rig.rows(id).map(\.text) == ["Long meeting"])
    }

    @Test func aSegmentIsNeverLongerThanFifteenSeconds() async throws {
        let rig = try SessionRig(texts: [95: "long speech"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(95, seconds: 40, closed: false)
        let session = rig.session(mic: mic, system: nil, withSystem: false)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        _ = await session.finish()
        let rows = try rig.rows(id)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.endMs - $0.startMs <= 15_000 })
        #expect(rows.first?.startMs == 1_000)
        #expect(rows.last?.endMs == 41_000)
    }

    // MARK: Model lease

    @Test func theLeaseIsReleasedAfterFinishingAndTheKeepWarmTimerRunsFromThere() async throws {
        let rig = try SessionRig(texts: [41: "Warm"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(41, seconds: 2)
        mic.silence(14)
        let session = rig.session(mic: mic, system: nil, withSystem: false)
        let log = SessionEventLog(session)
        try await session.start()
        rig.mic.push(mic.samples)
        #expect(await log.wait { if case .segmentSaved = $0 { true } else { false } })
        #expect(await rig.lease.activeLeases == 1)
        #expect(rig.warmSleeps.recorded.isEmpty)
        rig.mic.end()
        _ = await session.finish()
        #expect(await rig.lease.activeLeases == 0)
        let warm = rig.warmSleeps
        #expect(await warm.slept.wait { warm.recorded == [.seconds(321)] })
        #expect(rig.engine.isLoaded)
        rig.warmSleeps.expire()
        let engine = rig.engine
        #expect(await engine.unloaded.wait { !engine.isLoaded })
        #expect(rig.engine.loads == 1)
    }

    @Test func aBusyModelDefersEverySegmentToTheSpoolAndTheMeetingStaysIncomplete() async throws {
        let rig = try SessionRig(texts: [42: "Never heard"])
        // Dictation holds another model.
        let other = ScriptedEngine(texts: [:])
        let held = try await rig.lease.acquire(
            modelID: "other", folder: rig.directory.url.appending(path: "other"), engine: other,
            priority: .interactive, keepWarm: { .seconds(1) })
        var mic = TrackScript()
        mic.silence(1)
        mic.say(42, seconds: 2)
        mic.silence(14)
        let uuid = UUID()
        let session = rig.session(mic: mic, system: nil, uuid: uuid, withSystem: false)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        let outcome = await session.finish()
        await log.drain()
        #expect(log.contains { $0 == .modelUnavailable(busy: true) })
        #expect(outcome.result == .incomplete)
        #expect(outcome.unfinishedSegments == 1)
        #expect(outcome.failedSegments == 0)
        #expect(outcome.replayedSegments == 0)
        #expect(try rig.store.status(of: id) == .incomplete)
        #expect(try rig.store.audioState(of: id) == .spool)
        #expect(FileManager.default.fileExists(atPath: rig.spool.file(for: uuid, track: .mic).path))
        await held.release()
    }

    @Test func aFullBacklogDefersSegmentsToTheSpoolAndTheReplayFillsThemIn() async throws {
        let codes = [21, 22, 23, 24, 25, 26]
        let rig = try SessionRig(texts: Dictionary(uniqueKeysWithValues: codes.map { ($0, "Part \($0)") }))
        rig.engine.gate.close()
        var mic = TrackScript()
        for code in codes {
            mic.silence(0.5)
            mic.say(code, seconds: 14)
        }
        mic.silence(1)
        let session = rig.session(mic: mic, system: nil, withSystem: false)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        // The track ends only after every chunk was processed. The engine is held, so the worker's backlog
        // takes four segments (56 s) and the last two (28 s more would pass a minute) wait in the spool.
        #expect(await log.wait { $0 == .trackLost(.mic) })
        rig.engine.gate.open()
        let outcome = await session.finish()
        await log.drain()
        #expect(outcome.result == .ready)
        #expect(outcome.replayedSegments == 2)
        #expect(outcome.failedSegments == 0)
        #expect(outcome.unfinishedSegments == 0)
        #expect(try rig.rows(id).map(\.text) == codes.map { "Part \($0)" })
        let remaining = log.all.compactMap { event -> Int? in
            if case .replaying(let left) = event { left } else { nil }
        }
        #expect(remaining == [2, 1])
        // The live segments reached the engine in the order they were spoken.
        #expect(rig.engine.heard == codes)
    }

    @Test func aSegmentTheEngineCannotTranscribeKeepsTheMeetingIncompleteWithItsSpool() async throws {
        let rig = try SessionRig(texts: [43: "good", 44: "bad"])
        rig.engine.fail(44)
        var mic = TrackScript()
        mic.silence(1)
        mic.say(43, seconds: 2)
        mic.silence(1)
        mic.say(44, seconds: 2)
        mic.silence(12)
        let uuid = UUID()
        let session = rig.session(mic: mic, system: nil, uuid: uuid, withSystem: false)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        let outcome = await session.finish()
        // Tried live and once more from the spool, then left for a later run: nothing is deleted.
        #expect(rig.engine.heard.filter { $0 == 44 }.count == 2)
        #expect(outcome.result == .incomplete)
        #expect(outcome.failedSegments == 1)
        #expect(outcome.unfinishedSegments == 1)
        #expect(try rig.rows(id).map(\.text) == ["good"])
        #expect(try rig.store.status(of: id) == .incomplete)
        #expect(try rig.store.audioState(of: id) == .spool)
        #expect(FileManager.default.fileExists(atPath: rig.spool.file(for: uuid, track: .mic).path))
        #expect(await session.state == .incomplete)
    }

    @Test func aTransientTranscriptionErrorIsRetriedFromTheSpoolAndTheMeetingEndsReady() async throws {
        let rig = try SessionRig(texts: [43: "first", 44: "second", 45: "system words"])
        rig.engine.fail(43, times: 1)
        rig.engine.fail(45, times: 1)
        var mic = TrackScript()
        mic.silence(1)
        mic.say(43, seconds: 2)
        mic.silence(1)
        mic.say(44, seconds: 2)
        mic.silence(12)
        // The system track's first segment also fails once and holds the microphone text until the replay.
        var system = TrackScript()
        system.silence(0.5)
        system.say(45, seconds: 1)
        system.silence(18)
        let uuid = UUID()
        let session = rig.session(mic: mic, system: system, uuid: uuid)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.system.push(system.samples)
        rig.mic.end()
        rig.system.end()
        let outcome = await session.finish()
        #expect(outcome.result == .ready)
        #expect(outcome.replayedSegments == 2)
        #expect(outcome.failedSegments == 0)
        #expect(outcome.unfinishedSegments == 0)
        // The replayed microphone segment joins the held one in spoken order (held text is kept sorted).
        let order = try rig.store.read { db in
            try String.fetchAll(
                db, sql: "SELECT text FROM meeting_segment WHERE meeting_id = ? AND channel = 'mic' ORDER BY id",
                arguments: [id])
        }
        #expect(order == ["first", "second"])
        #expect(!FileManager.default.fileExists(atPath: rig.spool.directory(for: uuid).path))
    }

    @Test func finishWaitsForASegmentTheEngineIsStillTranscribing() async throws {
        let rig = try SessionRig(texts: [49: "Finished only after the drain"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(49, seconds: 2)
        mic.silence(14)
        let session = rig.session(mic: mic, system: nil, withSystem: false)
        let id = try await session.start()
        let engine = rig.engine
        engine.gate.close()
        rig.mic.push(mic.samples)
        #expect(await engine.transcribing.wait { engine.entered == 1 })
        let finishing = Task { await session.finish() }
        #expect(await spin { await session.state == .finishing })
        // The engine is held mid-transcription: the meeting is not finished and nothing is stored yet.
        #expect(try rig.store.status(of: id) == .processing)
        #expect(try rig.rows(id).isEmpty)
        engine.gate.open()
        let outcome = await finishing.value
        #expect(outcome.result == .ready)
        #expect(try rig.rows(id).map(\.text) == ["Finished only after the drain"])
    }

    // MARK: States, gate, events, sleep

    @Test func theStateMapsToTheMeetingStatusAndTheGoesThroughTheExpectedStates() async throws {
        #expect(MeetingSessionState.idle.meetingStatus == nil)
        #expect(MeetingSessionState.recording.meetingStatus == .recording)
        #expect(MeetingSessionState.finishing.meetingStatus == .processing)
        #expect(MeetingSessionState.processing.meetingStatus == .processing)
        #expect(MeetingSessionState.ready.meetingStatus == .ready)
        #expect(MeetingSessionState.incomplete.meetingStatus == .incomplete)
        #expect(MeetingSessionState.failed.meetingStatus == .failed)

        let rig = try SessionRig(texts: [45: "States"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(45, seconds: 2)
        mic.silence(14)
        let store = rig.store
        let seen = Mutex<MeetingStatus?>(nil)
        let session = rig.session(
            mic: mic, system: nil, withSystem: false,
            beforeReady: { id, _ in seen.withLock { $0 = try? store.status(of: id) } })
        let log = SessionEventLog(session)
        #expect(await session.state == .idle)
        try await session.start()
        #expect(await session.state == .recording)
        rig.mic.push(mic.samples)
        rig.mic.end()
        _ = await session.finish()
        await log.drain()
        #expect(seen.withLock { $0 } == .processing)
        let states = log.all.compactMap { event -> MeetingSessionState? in
            if case .stateChanged(let state) = event { state } else { nil }
        }
        #expect(states == [.recording, .finishing, .processing, .ready])
    }

    @Test func onlyOneSessionRunsAtATime() async throws {
        let rig = try SessionRig(texts: [46: "one"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(46, seconds: 2)
        mic.silence(14)
        let first = rig.session(mic: mic, system: nil, withSystem: false)
        try await first.start()
        let second = rig.session(mic: mic, system: nil, micInput: ControlledInput(), withSystem: false)
        await #expect(throws: MeetingSessionError.anotherSessionActive) { try await second.start() }
        #expect(try rig.store.meetingCount() == 1)
        #expect(await first.state == .recording)
        rig.mic.push(mic.samples)
        rig.mic.end()
        _ = await first.finish()
        // The gate is free again.
        let third = rig.session(mic: mic, system: nil, micInput: ControlledInput(), withSystem: false)
        try await third.start()
        await #expect(throws: MeetingSessionError.alreadyStarted) { try await third.start() }
        _ = await third.finish()
    }

    @Test func finishingASessionThatNeverStartedDoesNothing() async throws {
        let rig = try SessionRig()
        let session = rig.session(mic: TrackScript(), system: nil, withSystem: false)
        #expect(await session.finish().result == .notStarted)
        #expect(!rig.gate.isTaken)
    }

    @Test func theEventStreamCarriesLevelsTimeModelLoadingAndTheOutcome() async throws {
        let rig = try SessionRig(texts: [47: "Events"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(47, seconds: 2)
        mic.silence(14)
        let session = rig.session(mic: mic, system: nil, withSystem: false)
        let log = SessionEventLog(session)
        try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        let outcome = await session.finish()
        await log.drain()
        let events = log.all
        #expect(events.contains(.loadingModel))
        #expect(events.contains(.modelLoaded))
        #expect(events.contains(.elapsed(seconds: 1)))
        #expect(events.contains(.elapsed(seconds: 17)))
        #expect(events.contains { if case .segmentSaved(.mic, total: 1) = $0 { true } else { false } })
        #expect(events.last == .finished(outcome))
        // Levels come from the audio input itself (a fake that reports none) and are not required here.
        let text = String(describing: events)
        #expect(!text.contains("Events"))
    }

    @Test func theSleepAssertionIsHeldWhileRecordingAndReleasedOnEveryPath() async throws {
        // Normal end.
        let rig = try SessionRig(texts: [48: "Awake"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(48, seconds: 2)
        mic.silence(14)
        let session = rig.session(mic: mic, system: nil, withSystem: false)
        try await session.start()
        #expect(rig.sleepAssertion.isHeld)
        rig.mic.push(mic.samples)
        rig.mic.end()
        _ = await session.finish()
        #expect(!rig.sleepAssertion.isHeld)

        // Discarded meeting.
        var quiet = TrackScript()
        quiet.silence(3)
        let discarded = rig.session(mic: quiet, system: nil, micInput: ControlledInput(), withSystem: false)
        try await discarded.start()
        #expect(rig.sleepAssertion.isHeld)
        _ = await discarded.finish()
        #expect(!rig.sleepAssertion.isHeld)

        // Start that fails after the assertion was taken.
        let failing = rig.session(
            mic: quiet, system: nil, micInput: ControlledInput(failStart: true), withSystem: false)
        await #expect(throws: MeetingSessionError.noAudioInput) { try await failing.start() }
        #expect(!rig.sleepAssertion.isHeld)
        #expect(rig.sleepAssertion.holds == rig.sleepAssertion.releases)
        #expect(rig.sleepAssertion.holds == 3)
    }

    // MARK: Failures never delete audio

    private func blockSegmentWrites(_ rig: SessionRig) throws {
        try rig.store.write { db in
            try db.execute(
                sql:
                    "CREATE TRIGGER block_segments BEFORE INSERT ON meeting_segment BEGIN SELECT RAISE(ABORT, 'full'); END"
            )
        }
    }

    @Test func failedDatabaseWritesEndTheMeetingIncompleteWithTheSpoolKept() async throws {
        let rig = try SessionRig(texts: [61: "First", 62: "Second"])
        try blockSegmentWrites(rig)
        var mic = TrackScript()
        mic.silence(1)
        mic.say(61, seconds: 2)
        mic.silence(1)
        mic.say(62, seconds: 2)
        mic.silence(3)
        let uuid = UUID()
        let session = rig.session(mic: mic, system: nil, uuid: uuid, withSystem: false)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        let outcome = await session.finish()
        await log.drain()
        // Short, but something was heard: not discarded and no "nothing heard".
        #expect(outcome.result == .incomplete)
        #expect(outcome.writeFailures == 2)
        #expect(outcome.segmentCount == 0)
        #expect(outcome.unfinishedSegments == 2)
        #expect(log.all.filter { $0 == .databaseWriteFailed }.count == 1)
        #expect(!log.contains { $0 == .nothingHeard })
        #expect(try rig.store.meetingCount() == 1)
        #expect(try rig.store.status(of: id) == .incomplete)
        #expect(try rig.store.audioState(of: id) == .spool)
        #expect(FileManager.default.fileExists(atPath: rig.spool.file(for: uuid, track: .mic).path))
        #expect(await session.state == .incomplete)
    }

    @Test func anUnwritableDatabaseEndsTheMeetingFailedButStillKeepsTheSpool() async throws {
        let rig = try SessionRig(texts: [63: "Lost text"])
        try blockSegmentWrites(rig)
        try rig.store.write { db in
            try db.execute(
                sql: "CREATE TRIGGER block_status BEFORE UPDATE ON meeting BEGIN SELECT RAISE(ABORT, 'full'); END")
        }
        var mic = TrackScript()
        mic.silence(1)
        mic.say(63, seconds: 2)
        mic.silence(14)
        let uuid = UUID()
        let session = rig.session(mic: mic, system: nil, uuid: uuid, withSystem: false)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        let outcome = await session.finish()
        #expect(outcome.result == .failed)
        #expect(await session.state == .failed)
        #expect(try rig.store.status(of: id) == .recording)
        #expect(FileManager.default.fileExists(atPath: rig.spool.file(for: uuid, track: .mic).path))
        #expect(!rig.gate.isTaken)
        #expect(!rig.sleepAssertion.isHeld)
    }

    @Test func aMeetingIsNotMarkedReadyWhenTheStatusCannotBeWritten() async throws {
        let rig = try SessionRig(texts: [64: "Text"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(64, seconds: 2)
        mic.silence(14)
        let uuid = UUID()
        let store = rig.store
        // The hook runs right before the status is written: make that write fail.
        let session = rig.session(
            mic: mic, system: nil, uuid: uuid, withSystem: false,
            beforeReady: { _, _ in
                try? store.write { db in
                    try db.execute(
                        sql:
                            "CREATE TRIGGER block_ready BEFORE UPDATE ON meeting WHEN NEW.status = 'ready' BEGIN SELECT RAISE(ABORT, 'x'); END"
                    )
                }
            })
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        let outcome = await session.finish()
        #expect(outcome.result == .incomplete)
        #expect(try rig.store.status(of: id) == .incomplete)
        #expect(try rig.store.audioState(of: id) == .spool)
        #expect(FileManager.default.fileExists(atPath: rig.spool.file(for: uuid, track: .mic).path))
    }

    @Test func aSpoolThatCannotBeReadBackWithNothingSavedEndsFailed() async throws {
        let rig = try SessionRig(texts: [65: "Unreachable"])
        let other = ScriptedEngine(texts: [:])
        let held = try await rig.lease.acquire(
            modelID: "other", folder: rig.directory.url.appending(path: "other"), engine: other,
            priority: .interactive, keepWarm: { .seconds(1) })
        var mic = TrackScript()
        mic.silence(1)
        mic.say(65, seconds: 2)
        mic.silence(14)
        let uuid = UUID()
        let session = rig.session(mic: mic, system: nil, uuid: uuid, withSystem: false)
        let log = SessionEventLog(session)
        let id = try await session.start()
        #expect(await log.wait { $0 == .modelUnavailable(busy: true) })
        rig.mic.push(mic.samples)
        rig.mic.end()
        #expect(await log.wait { $0 == .trackLost(.mic) })
        // The model is free again for the replay, but the spool file is gone.
        await held.release()
        try FileManager.default.removeItem(at: rig.spool.file(for: uuid, track: .mic))
        let outcome = await session.finish()
        #expect(outcome.result == .failed)
        #expect(outcome.failedSegments == 1)
        #expect(outcome.unfinishedSegments == 0)
        #expect(try rig.store.status(of: id) == .failed)
        #expect(await session.state == .failed)
    }

    @Test func aLostSpoolOfOneTrackWithTextSavedFromTheOtherEndsIncomplete() async throws {
        let rig = try SessionRig(texts: [66: "Mic words that are gone", 67: "System words that survive"])
        let other = ScriptedEngine(texts: [:])
        let held = try await rig.lease.acquire(
            modelID: "other", folder: rig.directory.url.appending(path: "other"), engine: other,
            priority: .interactive, keepWarm: { .seconds(1) })
        var mic = TrackScript()
        mic.silence(1)
        mic.say(66, seconds: 2)
        mic.silence(14)
        var system = TrackScript()
        system.silence(5)
        system.say(67, seconds: 2)
        system.silence(10)
        let uuid = UUID()
        let session = rig.session(mic: mic, system: system, uuid: uuid)
        let log = SessionEventLog(session)
        let id = try await session.start()
        #expect(await log.wait { $0 == .modelUnavailable(busy: true) })
        rig.mic.push(mic.samples)
        rig.system.push(system.samples)
        rig.mic.end()
        rig.system.end()
        #expect(await log.wait { $0 == .trackLost(.system) })
        await held.release()
        try FileManager.default.removeItem(at: rig.spool.file(for: uuid, track: .mic))
        let outcome = await session.finish()
        #expect(outcome.result == .incomplete)
        #expect(outcome.failedSegments == 1)
        #expect(outcome.replayedSegments == 1)
        #expect(try rig.rows(id).map(\.text) == ["System words that survive"])
        #expect(try rig.store.audioState(of: id) == .spool)
    }

    // MARK: Echo against a late system track

    @Test func aMicrophoneEchoIsStillDroppedWhenTheSystemSegmentIsTranscribedFromTheSpoolLater() async throws {
        let said = "Welcome everyone to the weekly sync"
        let rig = try SessionRig(texts: [71: said, 72: said])
        rig.engine.fail(71, times: 1)
        var system = TrackScript()
        system.silence(1)
        system.say(71, seconds: 3)
        system.silence(16)
        var mic = TrackScript()
        mic.silence(1.2)
        mic.say(72, seconds: 3)
        mic.silence(16)
        let session = rig.session(mic: mic, system: system)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.system.push(system.samples)
        rig.mic.end()
        rig.system.end()
        let outcome = await session.finish()
        #expect(outcome.result == .ready)
        #expect(outcome.replayedSegments == 1)
        #expect(outcome.echoesDropped == 1)
        #expect(outcome.echoesUnchecked == 0)
        #expect(try rig.rows(id).map(\.channel) == ["system"])
    }

    @Test func microphoneTextIsNotHeldForeverWhileTheSystemTrackIsStuckAndPossibleDuplicatesAreFlagged() async throws {
        let said = "Welcome everyone to the weekly sync"
        let rig = try SessionRig(texts: [73: said, 74: said])
        rig.engine.fail(73)
        var system = TrackScript()
        system.silence(1)
        system.say(73, seconds: 3)
        system.silence(16)
        var mic = TrackScript()
        mic.silence(1.2)
        mic.say(74, seconds: 3)
        mic.silence(16)
        var limits = rig.shortLimits
        limits.micHoldLimit = .seconds(5)
        let session = rig.session(mic: mic, system: system, limits: limits)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.system.push(system.samples)
        // Written while the meeting still runs: a crash now would lose at most the hold time.
        #expect(await log.wait { if case .segmentSaved(.mic, _) = $0 { true } else { false } })
        #expect(await log.wait { $0 == .echoMayRemain })
        #expect(await session.state == .recording)
        #expect(try rig.rows(id).map(\.channel) == ["mic"])
        rig.mic.end()
        rig.system.end()
        let outcome = await session.finish()
        #expect(outcome.echoesUnchecked == 1)
        #expect(outcome.result == .incomplete)
        #expect(outcome.unfinishedSegments == 1)
    }

    // MARK: Wall clock

    @Test func aStalledStreamIsLostByTheHeartbeatAndTheMeetingFinishes() async throws {
        let rig = try SessionRig(texts: [81: "Said before the stream stalled"])
        let clock = TestClock()
        var mic = TrackScript()
        mic.silence(1)
        mic.say(81, seconds: 2)
        mic.silence(1)
        let session = rig.session(mic: mic, system: nil, withSystem: false, clock: clock)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        #expect(await log.wait { $0 == .elapsed(seconds: 4) })
        // No audio arrives any more and the stream does not end.
        clock.tick(advancing: 11)
        #expect(await log.wait { $0 == .trackLost(.mic) })
        #expect(await log.wait { if case .finished = $0 { true } else { false } })
        #expect(rig.mic.stops >= 1)
        #expect(try rig.store.status(of: id) == .ready)
        #expect(try rig.rows(id).map(\.text) == ["Said before the stream stalled"])
        #expect(!rig.sleepAssertion.isHeld)
    }

    @Test func theTimeLimitAlsoCountsWallClockTimeWhenNoAudioArrives() async throws {
        let rig = try SessionRig(texts: [82: "Some words"])
        let clock = TestClock()
        var mic = TrackScript()
        mic.silence(1)
        mic.say(82, seconds: 2)
        mic.silence(1)
        var limits = rig.shortLimits
        limits.maximumDuration = .seconds(60)
        limits.stallTimeout = .seconds(10_000)
        let session = rig.session(mic: mic, system: nil, limits: limits, withSystem: false, clock: clock)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        #expect(await log.wait { $0 == .elapsed(seconds: 4) })
        clock.tick(advancing: 61)
        #expect(await log.wait { $0 == .limitReached })
        #expect(await log.wait { if case .finished = $0 { true } else { false } })
        #expect(try rig.store.status(of: id) == .ready)
    }

    // MARK: Start races and retries

    @Test func finishingWhileTheSessionIsStillStartingEndsItAsSoonAsItHasStarted() async throws {
        let rig = try SessionRig()
        let slow = SlowStartInput()
        let session = rig.session(mic: TrackScript(), system: nil, withSystem: false, micAudio: slow)
        let starting = Task { try await session.start() }
        #expect(await slow.entered.wait { slow.isEntered })
        let finishing = Task { await session.finish() }
        #expect(await spin { await session.isFinishPending })
        slow.gate.open()
        _ = try await starting.value
        let outcome = await finishing.value
        #expect(outcome.result == .discarded)
        #expect(slow.inner.stops >= 1)
        #expect(!rig.sleepAssertion.isHeld)
        #expect(!rig.gate.isTaken)
        #expect(await session.state == .idle)
    }

    @Test func aSoleTrackThatEndsWhileStartingFinishesTheMeeting() async throws {
        let rig = try SessionRig()
        let session = rig.session(
            mic: TrackScript(), system: nil, micInput: ControlledInput(endOnStart: true), withSystem: false)
        let log = SessionEventLog(session)
        try await session.start()
        #expect(await log.wait { if case .finished(let outcome) = $0 { outcome.result == .discarded } else { false } })
        #expect(log.contains { $0 == .trackLost(.mic) })
        #expect(!rig.sleepAssertion.isHeld)
        #expect(!rig.gate.isTaken)
    }

    @Test func aStartThatFailedCanBeRetriedAndItsEventsKeepFlowing() async throws {
        let rig = try SessionRig(texts: [83: "Second attempt"])
        let input = ControlledInput(failStart: true)
        var mic = TrackScript()
        mic.silence(1)
        mic.say(83, seconds: 2)
        mic.silence(14)
        let session = rig.session(mic: mic, system: nil, micInput: input, withSystem: false)
        let log = SessionEventLog(session)
        await #expect(throws: MeetingSessionError.noAudioInput) { try await session.start() }
        #expect(try rig.store.meetingCount() == 0)
        input.setFailStart(false)
        let id = try await session.start()
        input.push(mic.samples)
        input.end()
        let outcome = await session.finish()
        await log.drain()
        #expect(outcome.result == .ready)
        #expect(log.contains { $0 == .stateChanged(.recording) })
        #expect(log.all.last == .finished(outcome))
        #expect(try rig.rows(id).map(\.text) == ["Second attempt"])
    }

    @Test func aLostTrackClosesTheSpeechItWasInTheMiddleOf() async throws {
        let rig = try SessionRig(texts: [84: "Cut off by the unplugged microphone"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(84, seconds: 3, closed: false)
        var system = TrackScript()
        system.silence(12)
        let session = rig.session(mic: mic, system: system)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.system.push(system.samples)
        rig.mic.end()
        #expect(await log.wait { if case .segmentSaved(.mic, _) = $0 { true } else { false } })
        #expect(await session.state == .recording)
        #expect(try rig.rows(id).map(\.text) == ["Cut off by the unplugged microphone"])
        _ = await session.finish()
    }
}
