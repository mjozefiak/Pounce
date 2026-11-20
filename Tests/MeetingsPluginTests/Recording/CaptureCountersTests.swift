import Foundation
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

/// Collects what `MeetingSession` publishes at the end of a meeting.
private final class CounterSink: Sendable {
    private let items = Mutex<[CaptureCounters]>([])
    var all: [CaptureCounters] { items.withLock { $0 } }
    var last: CaptureCounters? { items.withLock { $0.last } }
    var record: @Sendable (CaptureCounters) -> Void { { [self] counters in items.withLock { $0.append(counters) } } }
}

/// An engine whose model never loads (not a busy lease: the load itself fails).
private struct UnloadableEngine: SpeechEngine {
    struct LoadFailed: Error {}
    var isLoaded: Bool { false }
    func load(modelFolder: URL) async throws { throw LoadFailed() }
    func transcribe(_ samples: [Float]) async throws -> TranscriptSegment { throw LoadFailed() }
    func unload() async {}
}

/// An input that reports system-capture statistics, like `SystemAudioSource`.
private final class StatsInput: AudioInput, CaptureStatsProviding {
    let inner = ControlledInput()
    private let stats = Mutex(SystemCaptureStats())
    var captureStats: SystemCaptureStats { stats.withLock { $0 } }
    func set(_ new: SystemCaptureStats) { stats.withLock { $0 = new } }
    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws -> AsyncStream<[Float]> {
        try await inner.start(onLevel: onLevel)
    }
    func stop() async { await inner.stop() }
}

@Suite struct CaptureCountersTests {
    @Test func segmentsAreCountedPerChannelAndSpeechSentIsComparedWithTimeRecorded() async throws {
        let rig = try SessionRig(texts: [11: "Hello there", 12: "Reply"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(11, seconds: 3)
        mic.silence(12)
        var system = TrackScript()
        system.silence(5)
        system.say(12, seconds: 4)
        system.say(12, seconds: 0.3)
        system.silence(7)
        let sink = CounterSink()
        let session = rig.session(mic: mic, system: system, recordCounters: sink.record)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.system.push(system.samples)
        rig.mic.end()
        rig.system.end()
        _ = await session.finish()

        let counters = try #require(sink.last)
        #expect(counters.meetingID == id)
        #expect(counters.mic.vadSegmentsOpened == 1)
        #expect(counters.mic.vadSegmentsClosed == 1)
        #expect(counters.mic.segmentsSent == 1)
        #expect(counters.mic.speechSamplesSent == 3 * rate)
        #expect(counters.mic.recordedSamples == mic.samples.count)
        #expect(counters.mic.textResults == 1)
        #expect(counters.system.vadSegmentsOpened == 2)
        #expect(counters.system.vadSegmentsClosed == 2)
        #expect(counters.system.segmentsSent == 2)
        #expect(counters.system.shortSegments == 1)
        #expect(counters.system.speechSamplesSent == Int(4.3 * Double(rate)))
        #expect(counters.system.recordedSamples == system.samples.count)
        #expect(counters.system.hardCuts == 0)
        #expect(counters.system.emptyResults == 0)
        #expect(counters.audioGapWritten == false)
        #expect(try rig.store.hasAudioGap(id) == false)
    }

    @Test func aLongStretchOfSpeechCountsItsHardCuts() async throws {
        let rig = try SessionRig(texts: [31: "Long"])
        var system = TrackScript()
        system.silence(1)
        system.say(31, seconds: 20)
        system.silence(10)
        let sink = CounterSink()
        let session = rig.session(mic: TrackScript(), system: system, recordCounters: sink.record)
        _ = try await session.start()
        rig.system.push(system.samples)
        rig.system.end()
        _ = await session.finish()
        let counters = try #require(sink.last)
        #expect(counters.system.hardCuts == 1)
        #expect(counters.system.segmentsSent >= 2)
        #expect(counters.system.vadSegmentsOpened == 1)
    }

    @Test func anEmptyEngineResultIsCountedNotSilentlyForgotten() async throws {
        let rig = try SessionRig(texts: [41: "  ", 42: "Kept"])
        var system = TrackScript()
        system.silence(1)
        system.say(41, seconds: 2)
        system.silence(3)
        system.say(42, seconds: 2)
        system.silence(10)
        let sink = CounterSink()
        let session = rig.session(mic: TrackScript(), system: system, recordCounters: sink.record)
        let id = try await session.start()
        rig.system.push(system.samples)
        rig.system.end()
        _ = await session.finish()
        let counters = try #require(sink.last)
        #expect(counters.system.emptyResults == 1)
        #expect(counters.system.textResults == 1)
        #expect(try rig.rows(id).map(\.text) == ["Kept"])
    }

    @Test func aBusyModelIsCountedAsNoModelAndAsBusy() async throws {
        let rig = try SessionRig(texts: [51: "Never heard"])
        let held = try await rig.lease.acquire(
            modelID: "other", folder: rig.directory.url.appending(path: "other"), engine: ScriptedEngine(texts: [:]),
            priority: .interactive, keepWarm: { .seconds(1) })
        var mic = TrackScript()
        mic.silence(1)
        mic.say(51, seconds: 2)
        mic.silence(14)
        let sink = CounterSink()
        let session = rig.session(mic: mic, system: nil, withSystem: false, recordCounters: sink.record)
        _ = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        _ = await session.finish()
        let counters = try #require(sink.last)
        #expect(counters.modelBusy == 1)
        #expect(counters.mic.deferredNoModel == 1)
        #expect(counters.mic.textResults == 0)
        await held.release()
    }

    @Test func aFullBacklogIsCountedAndTheReplayResultsToo() async throws {
        let codes = [21, 22, 23, 24, 25, 26]
        let rig = try SessionRig(texts: Dictionary(uniqueKeysWithValues: codes.map { ($0, "Part \($0)") }))
        rig.engine.gate.close()
        var mic = TrackScript()
        for code in codes {
            mic.silence(0.5)
            mic.say(code, seconds: 14)
        }
        mic.silence(1)
        let sink = CounterSink()
        let session = rig.session(mic: mic, system: nil, withSystem: false, recordCounters: sink.record)
        let log = SessionEventLog(session)
        _ = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        #expect(await log.wait { $0 == .trackLost(.mic) })
        rig.engine.gate.open()
        _ = await session.finish()
        let counters = try #require(sink.last)
        #expect(counters.mic.backlogDeferred == 2)
        #expect(counters.mic.replayedText == 2)
        #expect(counters.mic.replayedEmpty == 0)
        #expect(counters.mic.replayedFailed == 0)
        #expect(counters.mic.segmentsSent == 4)
        #expect(counters.mic.textResults == 4)
    }

    @Test func aFailedSegmentIsCountedAndSoIsItsFailedReplay() async throws {
        let rig = try SessionRig(texts: [61: "Never"])
        rig.engine.fail(61)
        var mic = TrackScript()
        mic.silence(1)
        mic.say(61, seconds: 2)
        mic.silence(14)
        let sink = CounterSink()
        let session = rig.session(mic: mic, system: nil, withSystem: false, recordCounters: sink.record)
        _ = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        _ = await session.finish()
        let counters = try #require(sink.last)
        #expect(counters.mic.failedResults == 1)
        #expect(counters.mic.replayedFailed == 1)
    }

    @Test func aRestartFillsTheGapAndWritesAudioGapWhileTheMeetingIsStillRecording() async throws {
        let rig = try SessionRig(texts: [:])
        var mic = TrackScript()
        mic.silence(16)
        var limits = rig.shortLimits
        limits.resumeAttempts = 1
        limits.resumeDelay = .milliseconds(1)
        let clock = TestClock()
        let sink = CounterSink()
        let session = rig.session(mic: mic, system: nil, limits: limits, clock: clock, recordCounters: sink.record)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(Array(mic.samples[0..<2 * rate]))
        #expect(await log.wait { $0 == .elapsed(seconds: 2) })
        clock.tick(advancing: 3)
        rig.mic.end()
        #expect(await log.wait { $0 == .trackResumed(.mic) })
        // Written live, before the meeting is finished.
        #expect(try rig.store.hasAudioGap(id))
        rig.mic.push(Array(mic.samples.dropFirst(5 * rate)))
        _ = await session.finish()
        let counters = try #require(sink.last)
        #expect(counters.mic.interruptions == 1)
        #expect(counters.mic.resumes == 1)
        #expect(counters.mic.gapFillSamples > 0)
        #expect(counters.audioGapWritten)
    }

    @Test func aLostTrackIsCounted() async throws {
        let rig = try SessionRig(texts: [:])
        var mic = TrackScript()
        mic.silence(16)
        var system = TrackScript()
        system.silence(16)
        let sink = CounterSink()
        let session = rig.session(mic: mic, system: system, recordCounters: sink.record)
        let log = SessionEventLog(session)
        _ = try await session.start()
        rig.mic.push(mic.samples)
        rig.system.end()
        #expect(await log.wait { $0 == .trackLost(.system) })
        _ = await session.finish()
        let counters = try #require(sink.last)
        #expect(counters.system.lost == 1)
        #expect(counters.mic.lost == 0)
    }

    @Test func theSystemSourceStatisticsReachTheCountersAndWriteAudioGap() async throws {
        let rig = try SessionRig(texts: [:])
        let input = StatsInput()
        var system = TrackScript()
        system.silence(16)
        let sink = CounterSink()
        let session = rig.session(
            mic: TrackScript(), system: system, systemAudio: input, recordCounters: sink.record)
        let id = try await session.start()
        input.set(
            SystemCaptureStats(
                tapsRecreated: 1, recreateFailures: 0, formatChanges: 2, timelineResyncs: 3,
                outputChangesNotObserved: 1, silenceInsertedSamples: 8_000, ringDropped: 4))
        input.inner.push(system.samples)
        input.inner.end()
        _ = await session.finish()
        let counters = try #require(sink.last)
        #expect(counters.system.ringDropped == 4)
        #expect(counters.system.silenceInsertedSamples == 8_000)
        #expect(counters.system.tapsRecreated == 1)
        #expect(counters.system.formatChanges == 2)
        #expect(counters.system.timelineResyncs == 3)
        #expect(counters.system.outputChangesNotObserved == 1)
        #expect(counters.mic == ChannelCounters() || counters.mic.tapsRecreated == 0)
        #expect(counters.audioGapWritten)
        #expect(try rig.store.hasAudioGap(id))
    }

    @Test func countersWithoutAHoleLeaveAudioGapAlone() async throws {
        let rig = try SessionRig(texts: [:])
        let input = StatsInput()
        input.set(SystemCaptureStats(tapsRecreated: 1, formatChanges: 1))
        var system = TrackScript()
        system.silence(16)
        let sink = CounterSink()
        let session = rig.session(
            mic: TrackScript(), system: system, systemAudio: input, recordCounters: sink.record)
        let id = try await session.start()
        input.inner.push(system.samples)
        input.inner.end()
        _ = await session.finish()
        #expect(try sink.last?.system.tapsRecreated == 1)
        #expect(try rig.store.hasAudioGap(id) == false)
    }

    @Test func aMeetingDiscardedAsQuietStillRecordsItsCounters() async throws {
        // The engine heard the speech but returned nothing: the meeting is "silent" and thrown away, which is
        // exactly the case the counters must show.
        let rig = try SessionRig(texts: [81: "  "])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(81, seconds: 2)
        mic.silence(2)
        let sink = CounterSink()
        let session = rig.session(mic: mic, system: nil, withSystem: false, recordCounters: sink.record)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        let outcome = await session.finish()
        #expect(outcome.result == .discarded)
        #expect(try rig.store.meetingCount() == 0)
        let counters = try #require(sink.last)
        #expect(counters.discarded)
        #expect(counters.meetingID == id)
        #expect(counters.mic.segmentsSent == 1)
        #expect(counters.mic.emptyResults == 1)
        #expect(counters.mic.recordedSamples == mic.samples.count)
        #expect(CaptureDiagnostics.report([counters]).contains("discarded as quiet"))
    }

    @Test func emptyRangesUnmatchedEndsAndForcedClosesAreCounted() async throws {
        let rig = try SessionRig(texts: [91: "First", 92: "Open at the end"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(91, seconds: 3)
        // A start and an end at the same sample: a segment of zero length.
        mic.say(93, seconds: 0)
        mic.silence(2)
        // A second span inside the first: its end closes the segment, the outer end then has nothing open.
        mic.span(2 * rate..<3 * rate)
        mic.say(92, seconds: 2, closed: false)
        let sink = CounterSink()
        let session = rig.session(mic: mic, system: nil, withSystem: false, recordCounters: sink.record)
        _ = try await session.start()
        rig.mic.push(mic.samples)
        _ = await session.finish()
        let counters = try #require(sink.last)
        #expect(counters.mic.emptyRanges == 1)
        #expect(counters.mic.vadUnmatchedEnds == 1)
        #expect(counters.mic.forcedCloses == 1)
        #expect(counters.mic.vadSegmentsOpened == 3)
        #expect(counters.mic.vadSegmentsClosed == 2)
    }

    @Test func spoolResultsOfAFullSharedQueueAreCountedAndReplayed() async throws {
        let rig = try SessionRig(texts: [76: "Part one", 77: "Part two"])
        rig.engine.gate.close()
        // Another user of the same model (dictation, say) already has the background queue's 60 s waiting.
        let other = try await rig.lease.acquire(
            modelID: "test-model", folder: rig.directory.url.appending(path: "model"), engine: rig.engine,
            priority: .background, keepWarm: { .seconds(1) })
        let waiting = Task {
            try await other.transcribe([Float](repeating: 1, count: SpeechEngineLease.backgroundLimit))
        }
        #expect(await rig.engine.transcribing.wait { rig.engine.entered == 1 })
        var mic = TrackScript()
        mic.silence(1)
        mic.say(76, seconds: 2)
        mic.silence(1)
        mic.say(77, seconds: 2)
        mic.silence(10)
        let sink = CounterSink()
        let session = rig.session(mic: mic, system: nil, withSystem: false, recordCounters: sink.record)
        let log = SessionEventLog(session)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        #expect(await log.wait { $0 == .trackLost(.mic) })
        // The queue stays full until the meeting is finished: `finish()` waits for every segment's result before
        // the replay, so both get `.spool`, and the replay of a still-full queue keeps them in the spool.
        let outcome = await session.finish()
        rig.engine.gate.open()
        _ = try await waiting.value
        await other.release()
        let counters = try #require(sink.last)
        #expect(counters.meetingID == id)
        #expect(counters.mic.segmentsSent == 2)
        #expect(counters.mic.spoolResults == 2)
        #expect(counters.mic.textResults == 0)
        #expect(counters.mic.backlogDeferred == 0)
        #expect(counters.mic.replayedText == 0)
        #expect(counters.mic.replayedFailed == 2)
        #expect(outcome.unfinishedSegments == 2)
    }

    @Test func aSegmentWhoseSpoolCannotBeReadBackIsCountedAsLost() async throws {
        let rig = try SessionRig(texts: [65: "Unreachable"])
        let held = try await rig.lease.acquire(
            modelID: "other", folder: rig.directory.url.appending(path: "other"), engine: ScriptedEngine(texts: [:]),
            priority: .interactive, keepWarm: { .seconds(1) })
        var mic = TrackScript()
        mic.silence(1)
        mic.say(65, seconds: 2)
        mic.silence(14)
        let uuid = UUID()
        let sink = CounterSink()
        let session = rig.session(
            mic: mic, system: nil, uuid: uuid, withSystem: false, recordCounters: sink.record)
        let log = SessionEventLog(session)
        _ = try await session.start()
        #expect(await log.wait { $0 == .modelUnavailable(busy: true) })
        await held.release()
        try FileManager.default.removeItem(at: rig.spool.file(for: uuid, track: .mic))
        rig.mic.push(mic.samples)
        rig.mic.end()
        #expect(await log.wait { $0 == .trackLost(.mic) })
        _ = await session.finish()
        let counters = try #require(sink.last)
        #expect(counters.mic.deferredNoModel == 1)
        #expect(counters.mic.replayUnreadable == 1)
        #expect(CaptureDiagnostics.report([counters]).contains("unreadable in the spool: 1"))
    }

    @Test func aModelThatCannotLoadIsCountedAsUnavailableNotBusy() async throws {
        let rig = try SessionRig(texts: [111: "Never"])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(111, seconds: 2)
        mic.silence(14)
        let sink = CounterSink()
        let session = rig.session(
            mic: mic, system: nil, engine: UnloadableEngine(), withSystem: false, recordCounters: sink.record)
        _ = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        _ = await session.finish()
        let counters = try #require(sink.last)
        #expect(counters.modelUnavailable == 1)
        #expect(counters.modelBusy == 0)
        #expect(counters.mic.deferredNoModel == 1)
    }

    @Test func theCountersOnlyObserveWhatReachesTheEngineAndTheTranscript() async throws {
        // The segmentation of a fixed script, pinned: the same engine calls and rows as before the counters
        // existed (a hard cut at 15 s, a zero-length range that sends nothing), whether the counters are kept.
        for recording in [false, true] {
            let rig = try SessionRig(texts: [121: "One", 122: "Two"])
            var mic = TrackScript()
            mic.silence(1)
            mic.say(121, seconds: 3)
            mic.say(123, seconds: 0)
            mic.silence(1)
            mic.say(122, seconds: 20)
            mic.silence(12)
            let sink = CounterSink()
            let ignore: @Sendable (CaptureCounters) -> Void = { _ in }
            let session = rig.session(
                mic: mic, system: nil, withSystem: false, recordCounters: recording ? sink.record : ignore)
            let id = try await session.start()
            rig.mic.push(mic.samples)
            rig.mic.end()
            _ = await session.finish()
            #expect(rig.engine.heard.sorted() == [121, 122, 122])
            #expect(try rig.rows(id).map(\.text) == ["One", "Two", "Two"])
            #expect(sink.all.count == (recording ? 1 : 0))
        }
    }

    // MARK: Privacy

    @Test func noTranscriptTextNameTitleOrDeviceNameReachesTheReportTheLogLinesOrTheFile() async throws {
        let secrets = ["Zażółć gęślą jaźń", "Anna Kowalska", "Quarterly Budget Review", "Anker PowerConf"]
        let rig = try SessionRig(texts: [71: secrets[0]])
        var mic = TrackScript()
        mic.silence(1)
        mic.say(71, seconds: 3)
        mic.silence(12)
        let sink = CounterSink()
        let session = rig.session(mic: mic, system: nil, withSystem: false, recordCounters: sink.record)
        let id = try await session.start()
        try rig.store.write { db in
            try db.execute(sql: "UPDATE meeting SET title = ? WHERE id = ?", arguments: [secrets[2], id])
        }
        rig.mic.push(mic.samples)
        rig.mic.end()
        _ = await session.finish()
        let counters = try #require(sink.last)

        let report = CaptureDiagnostics.report([counters])
        let directory = rig.directory.url.appending(path: "counters")
        let store = CaptureCountersStore(directory: directory)
        try store.record(counters)
        let json = try String(contentsOf: directory.appending(path: CaptureCountersStore.fileName), encoding: .utf8)
        for secret in secrets {
            #expect(!report.contains(secret))
            #expect(!json.contains(secret))
        }
        // The file holds only numbers and booleans.
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        func onlyNumbers(_ value: Any) -> Bool {
            switch value {
            case let array as [Any]: return array.allSatisfy(onlyNumbers)
            case let dictionary as [String: Any]: return dictionary.values.allSatisfy(onlyNumbers)
            case is NSNumber: return true
            default: return false
            }
        }
        #expect(onlyNumbers(object))
        // The report names the channels and counts, nothing else.
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 :,.[]\n-")
        #expect(report.unicodeScalars.allSatisfy { allowed.contains($0) })
    }
}

@Suite struct CaptureCountersStoreTests {
    /// A library with three finished meetings (one 100 days old) and the counters of each, plus one of a meeting
    /// that was discarded as quiet.
    private func library() throws -> (MeetingsStore, TemporaryDirectory, ids: [Int64]) {
        let directory = try TemporaryDirectory()
        let store = try MeetingsStore.open(in: directory.url.appending(path: "meetings"), keys: testKeys())
        var ids: [Int64] = []
        for (index, age) in [100.0, 1, 1].enumerated() {
            let id = try store.insertMeeting(
                uuid: UUID().uuidString.lowercased(), startedAt: Date().addingTimeInterval(-age * 86_400),
                speechModelID: "m")
            try store.setStatus(id, status: .ready)
            ids.append(id)
            var counters = CaptureCounters()
            counters.meetingID = id
            counters.mic.segmentsSent = index
            try #require(store.captureCounters).record(counters)
        }
        var quiet = CaptureCounters()
        quiet.meetingID = 999
        quiet.discarded = true
        try #require(store.captureCounters).record(quiet)
        return (store, directory, ids)
    }

    private func saved(_ store: MeetingsStore) throws -> [Int64] {
        try #require(store.captureCounters).load().filter { !$0.discarded }.map(\.meetingID)
    }

    private func discardedKept(_ store: MeetingsStore) throws -> Bool {
        try #require(store.captureCounters).load().contains { $0.discarded }
    }

    @Test func theCountersFileLivesInThePluginFolderNextToTheLibrary() throws {
        let (store, directory, _) = try library()
        let file = directory.url.appending(path: "meetings").appending(path: CaptureCountersStore.fileName)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try saved(store).count == 3)
    }

    @Test func retentionPrunesTheCountersOfTheMeetingsItDeletes() throws {
        let (store, directory, ids) = try library()
        defer { _ = directory }
        _ = try store.applyRetention(cutoff: Date().addingTimeInterval(-90 * 86_400))
        #expect(try saved(store) == [ids[1], ids[2]])
        // A discarded meeting has no row; its entry is one of the last 20 and stays.
        #expect(try discardedKept(store))
    }

    @Test func aSingleDeletePrunesThatMeetingsCounters() throws {
        let (store, directory, ids) = try library()
        defer { _ = directory }
        #expect(try store.deleteMeeting(ids[1], spool: RecordingSpool()))
        #expect(try saved(store) == [ids[0], ids[2]])
        try store.deleteMeetings([ids[2]])
        #expect(try saved(store) == [ids[0]])
    }

    @Test func clearLibraryPrunesEveryDeletedMeetingAndTheDiscardedOnes() throws {
        let (store, directory, ids) = try library()
        defer { _ = directory }
        let live = try store.insertMeeting(uuid: "live", startedAt: Date(), speechModelID: "m")
        var counters = CaptureCounters()
        counters.meetingID = live
        try #require(store.captureCounters).record(counters)
        _ = try store.deleteFinishedMeetings()
        #expect(try saved(store) == [live])
        #expect(try !discardedKept(store))
        #expect(!ids.contains(live))
    }

    @Test func aDiscardedMeetingNeitherReplacesNorIsReplacedByAnEntryWithTheSameNumber() throws {
        let directory = try TemporaryDirectory()
        let store = CaptureCountersStore(directory: directory.url)
        var quiet = CaptureCounters()
        quiet.meetingID = 4
        quiet.discarded = true
        try store.record(quiet)
        // SQLite hands the freed id to the next meeting.
        var next = CaptureCounters()
        next.meetingID = 4
        try store.record(next)
        try store.record(next)
        #expect(store.load().map(\.discarded) == [true, false])
    }

    @Test func itKeepsTheLastTwentyMeetingsReplacesTheSameOneAndWritesPrivateFiles() throws {
        let directory = try TemporaryDirectory()
        let store = CaptureCountersStore(directory: directory.url.appending(path: "meetings"))
        #expect(store.load().isEmpty)
        for id in 1...25 {
            var counters = CaptureCounters()
            counters.meetingID = Int64(id)
            try store.record(counters)
        }
        var again = CaptureCounters()
        again.meetingID = 25
        again.system.hardCuts = 9
        try store.record(again)
        let loaded = store.load()
        #expect(loaded.count == CaptureCountersStore.keep)
        #expect(loaded.first?.meetingID == 6)
        #expect(loaded.last?.system.hardCuts == 9)
        let file = directory.url.appending(path: "meetings").appending(path: CaptureCountersStore.fileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func aDamagedFileReadsAsEmptyAndIsReplacedByTheNextWrite() throws {
        let directory = try TemporaryDirectory()
        let folder = directory.url.appending(path: "meetings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appending(path: CaptureCountersStore.fileName))
        let store = CaptureCountersStore(directory: folder)
        #expect(store.load().isEmpty)
        try store.record(CaptureCounters())
        #expect(store.load().count == 1)
    }

    @Test func theReportListsEveryCounterOfBothChannels() {
        var counters = CaptureCounters()
        counters.meetingID = 7
        counters.durationMs = 61_000
        counters.system.ringDropped = 3
        counters.system.hardCuts = 2
        counters.mic.emptyResults = 4
        let report = CaptureDiagnostics.report([counters])
        #expect(report.contains("Meeting 7: 61 s"))
        #expect(report.contains("ring buffers dropped: 3"))
        #expect(report.contains("[system] VAD segments opened"))
        #expect(report.contains("[mic] segments sent"))
        #expect(report.contains("hard cuts: 2"))
        #expect(report.contains("empty results dropped: 4"))
        #expect(!report.contains("[mic] taps recreated"))
    }
}
