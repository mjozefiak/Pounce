import Foundation
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
        #expect(await eventually { log.contains { if case .segmentSaved = $0 { true } else { false } } })
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
        #expect(await eventually { log.contains { if case .segmentSaved = $0 { true } else { false } } })
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
        #expect(await eventually { log.contains { $0 == .trackLost(.mic) } })
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
        #expect(await eventually { log.contains { $0 == .trackLost(.system) } })
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
        #expect(await eventually { log.contains { $0 == .lowDisk } })
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
        #expect(await eventually { log.contains { if case .finished = $0 { true } else { false } } })
        let events = log.all
        let countdown = events.compactMap { event -> Int? in
            if case .limitApproaching(let left) = event { left } else { nil }
        }
        #expect(countdown.first == 4 || countdown.first == 3)
        #expect(countdown == countdown.sorted(by: >))
        #expect(events.contains(.limitReached))
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
        #expect(await eventually { log.contains { if case .segmentSaved = $0 { true } else { false } } })
        #expect(await rig.lease.activeLeases == 1)
        #expect(rig.warmSleeps.recorded.isEmpty)
        rig.mic.end()
        _ = await session.finish()
        #expect(await rig.lease.activeLeases == 0)
        #expect(await eventually { rig.warmSleeps.recorded == [.seconds(321)] })
        #expect(rig.engine.isLoaded)
        rig.warmSleeps.expire()
        #expect(await eventually { !rig.engine.isLoaded })
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
        #expect(try rig.store.status(of: id) == .incomplete)
        #expect(try rig.store.audioState(of: id) == .spool)
        #expect(FileManager.default.fileExists(atPath: rig.spool.file(for: uuid, track: .mic).path))
        await held.release()
    }

    @Test func anOverflowedBackgroundQueueDefersSegmentsToTheSpoolAndTheReplayFillsThemIn() async throws {
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
        // The first segments fill the background queue (a minute of audio); the engine is held, so the rest
        // is refused and waits in the spool.
        #expect(await eventually { rig.engine.heard.isEmpty && log.contains { $0 == .trackLost(.mic) } })
        try await Task.sleep(for: .milliseconds(200))
        rig.engine.gate.open()
        let outcome = await session.finish()
        await log.drain()
        #expect(outcome.result == .ready)
        #expect(outcome.replayedSegments >= 1)
        #expect(outcome.failedSegments == 0)
        let rows = try rig.rows(id)
        #expect(rows.map(\.text) == codes.map { "Part \($0)" }, "\(rows.map(\.text)) \(outcome)")
        #expect(log.contains { if case .replaying = $0 { true } else { false } })
    }

    @Test func aSegmentTheEngineCannotTranscribeIsCountedAndTheRestIsKept() async throws {
        let rig = try SessionRig(texts: [43: "good", 44: "bad"])
        rig.engine.fail(44)
        var mic = TrackScript()
        mic.silence(1)
        mic.say(43, seconds: 2)
        mic.silence(1)
        mic.say(44, seconds: 2)
        mic.silence(12)
        let session = rig.session(mic: mic, system: nil, withSystem: false)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        let outcome = await session.finish()
        #expect(outcome.result == .ready)
        #expect(outcome.failedSegments == 1)
        #expect(try rig.rows(id).map(\.text) == ["good"])
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
}
