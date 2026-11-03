import Foundation
import GRDB
import PounceKit
import PouncePersistence
import PounceSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

/// Mic: 1 s silence, utterance 11 (1-4 s), 2 s silence, utterance 12 (6-9 s), 3 s silence = 12 s.
private func micScript() -> TrackScript {
    .build([(1, 11, 3), (2, 12, 3)], tail: 3)
}

/// System: 6 s silence, utterance 21 (6-9 s), 3 s silence = 12 s.
private func systemScript() -> TrackScript {
    .build([(6, 21, 3)], tail: 3)
}

private let texts: [Int: String] = [11: "Pierwsza wypowiedź", 12: "Druga wypowiedź", 21: "Odpowiedź drugiej strony"]

@MainActor
@Suite struct RecoveryJobTests {
    // MARK: Crash while recording

    @Test func aMeetingStillRecordingAfterACrashBecomesIncompleteAndKeepsItsSpool() throws {
        let rig = try RecoveryRig(texts: texts)
        let mic = micScript()
        let meeting = try rig.seed(
            .recording, mic: mic, system: systemScript(), stored: [(.mic, 16_000..<64_000, "Pierwsza wypowiedź")])
        // The crash cut the last frame in the middle of a write.
        let file = rig.spool.file(for: meeting.uuid, track: .mic)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: try handle.seekToEnd() - 10)
        try handle.close()

        let library = rig.library(resumer: rig.resumerFactory(mic: mic, system: systemScript()))
        library.open()
        let store = try #require(library.store)

        #expect(try store.status(of: meeting.id) == .incomplete)
        #expect(try store.audioState(of: meeting.id) == .spool)
        #expect(rig.spoolExists(meeting.uuid))
        #expect(try store.segmentCount(meetingID: meeting.id) == 1)
        #expect(library.lastRecovery?.incomplete == [meeting.id])
        #expect(library.lastRecovery?.toResume.isEmpty == true)
        // Recording is never resumed and nothing is transcribed at activation.
        #expect(rig.engine.loads == 0)
        #expect(rig.engine.heard.isEmpty)
        // What was recorded can still be read: the spool ends without its end marker.
        let reader = try SpoolReader(file: file, meeting: meeting.uuid, track: .mic, keys: rig.keys)
        var frames = 0
        while try reader.nextSamples() != nil { frames += 1 }
        #expect(frames > 0)
        #expect(reader.endState == .truncatedMidFrame)
        // The duration is known from what was saved.
        let recovered = try #require(try store.recoverableMeeting(id: meeting.id))
        #expect(recovered.durationMs == 4_000)
        #expect(recovered.endedAt != nil)
    }

    // MARK: Crash while processing

    @Test func aProcessingMeetingIsResumedToReadyAndOnlyThenItsSpoolIsDeleted() async throws {
        let rig = try RecoveryRig(texts: texts)
        let mic = micScript()
        let system = systemScript()
        // The first mic utterance and the system one reached the library; the second mic one is missing.
        let meeting = try rig.seed(
            .processing, mic: mic, system: system,
            stored: [(.mic, 16_000..<64_000, texts[11]!), (.system, 96_000..<144_000, texts[21]!)])

        let library = rig.library(resumer: rig.resumerFactory(mic: mic, system: system))
        library.open()
        let store = try #require(library.store)
        // Right after the pass the meeting is still `processing`: retention and "Dokończ" stay away.
        #expect(library.lastRecovery?.toResume.map(\.id) == [meeting.id])

        #expect(await eventually { (try? store.audioState(of: meeting.id)) == .deleted })
        #expect(try store.audioState(of: meeting.id) == .deleted)
        #expect(!rig.spoolExists(meeting.uuid))
        let rows = try rig.rows(library, meeting.id)
        #expect(rows.map(\.text) == [texts[11]!, texts[21]!, texts[12]!])
        #expect(rows.map(\.startMs) == [1_000, 6_000, 6_000])
        #expect(rows.filter { $0.text == texts[12]! }.count == 1)
        // Silence was never transcribed and stored text was not transcribed twice.
        #expect(rig.engine.heard == [12])
        // The finalizer ran once, before the meeting became ready, while the spool still existed.
        #expect(
            rig.finalizations.calls == [.init(meetingID: meeting.id, statusDuringCall: .processing, spoolExisted: true)]
        )
        let done = try #require(try store.recoverableMeeting(id: meeting.id))
        #expect(done.durationMs == 12_000)
        #expect(await rig.lease.activeLeases == 0)
    }

    @Test func aMeetingWhoseTranscriptIsCompleteSkipsTheModelAndJustFinalizes() async throws {
        let rig = try RecoveryRig(texts: texts)
        let mic = micScript()
        let meeting = try rig.seed(
            .processing, mic: mic,
            stored: [(.mic, 16_000..<64_000, texts[11]!), (.mic, 96_000..<144_000, texts[12]!)])
        let library = rig.library(resumer: rig.resumerFactory(mic: mic))
        library.open()
        let store = try #require(library.store)
        #expect(await eventually { (try? store.audioState(of: meeting.id)) == .deleted })
        #expect(rig.engine.loads == 0)
        #expect(rig.finalizations.calls.count == 1)
        #expect(!rig.spoolExists(meeting.uuid))
        #expect(try store.segmentCount(meetingID: meeting.id) == 2)
    }

    @Test func withoutASpeechSetupAProcessingMeetingBecomesIncompleteAtOnce() throws {
        let rig = try RecoveryRig(texts: texts)
        let meeting = try rig.seed(.processing, mic: micScript())
        let library = rig.library()
        library.open()
        #expect(try library.store?.status(of: meeting.id) == .incomplete)
        #expect(rig.spoolExists(meeting.uuid))
        #expect(library.finish(meetingID: meeting.id) == nil)
    }

    @Test func aMissingSpeechModelLeavesTheResumedMeetingIncompleteWithItsSpool() async throws {
        let rig = try RecoveryRig(texts: texts)
        let mic = micScript()
        let meeting = try rig.seed(.processing, mic: mic, stored: [(.mic, 16_000..<64_000, texts[11]!)])
        let library = rig.library(resumer: rig.resumerFactory(mic: mic, haveModel: false))
        library.open()
        let store = try #require(library.store)
        #expect(await eventually { (try? store.status(of: meeting.id)) == .incomplete })
        #expect(rig.spoolExists(meeting.uuid))
        #expect(try store.audioState(of: meeting.id) == .spool)
        #expect(rig.finalizations.calls.isEmpty)
        #expect(try store.segmentCount(meetingID: meeting.id) == 1)
    }

    // MARK: Failed and unreadable

    enum Scenario: CaseIterable, CustomStringConvertible {
        case recordingWrongKeyNoSegments
        case processingWrongKeyNoSegments
        case recordingNoSpoolNoSegments
        case recordingWrongKeyWithSegments
        case processingWrongKeyWithSegments
        case processingNoSpoolWithSegments

        var description: String {
            switch self {
            case .recordingWrongKeyNoSegments: "recording, wrong key, no segments"
            case .processingWrongKeyNoSegments: "processing, wrong key, no segments"
            case .recordingNoSpoolNoSegments: "recording, no spool, no segments"
            case .recordingWrongKeyWithSegments: "recording, wrong key, segments"
            case .processingWrongKeyWithSegments: "processing, wrong key, segments"
            case .processingNoSpoolWithSegments: "processing, no spool, segments"
            }
        }

        var status: MeetingStatus {
            switch self {
            case .recordingWrongKeyNoSegments, .recordingNoSpoolNoSegments, .recordingWrongKeyWithSegments:
                .recording
            default: .processing
            }
        }

        var hasSpool: Bool { self != .recordingNoSpoolNoSegments && self != .processingNoSpoolWithSegments }

        var hasSegments: Bool {
            self == .recordingWrongKeyWithSegments || self == .processingWrongKeyWithSegments
                || self == .processingNoSpoolWithSegments
        }

        var expected: MeetingStatus { hasSegments ? .incomplete : .failed }
    }

    @Test(arguments: Scenario.allCases)
    func theFailedRulesFollowTheSpoolAndTheSegments(_ scenario: Scenario) async throws {
        let rig = try RecoveryRig(texts: texts)
        let mic = micScript()
        let other = try testKeys(77)
        let meeting = try rig.seed(
            scenario.status, mic: mic,
            stored: scenario.hasSegments ? [(.mic, 16_000..<64_000, texts[11]!)] : [], spoolKeys: other,
            writeSpool: scenario.hasSpool)
        let library = rig.library(resumer: rig.resumerFactory(mic: mic))
        library.open()
        let store = try #require(library.store)

        #expect(try store.status(of: meeting.id) == scenario.expected)
        #expect(library.lastRecovery?.toResume.isEmpty == true)
        // An unreadable spool is never deleted by recovery; a missing one is recorded as such.
        #expect(rig.spoolExists(meeting.uuid) == scenario.hasSpool)
        #expect(try store.audioState(of: meeting.id) == (scenario.hasSpool ? .spool : .deleted))
        // What is in the library stays.
        #expect(try store.segmentCount(meetingID: meeting.id) == (scenario.hasSegments ? 1 : 0))
        // Nothing was transcribed, nothing finalized.
        #expect(rig.engine.loads == 0)
        #expect(rig.finalizations.calls.isEmpty)
    }

    @Test func aLibraryThatCannotBeWrittenKeepsTheStatusAndTheSpool() throws {
        let rig = try RecoveryRig(texts: texts)
        let meeting = try rig.seed(.recording, mic: micScript())
        let store = try #require(rig.seedStoreForTests)
        try store.write { db in
            try db.execute(sql: "CREATE TRIGGER readonly BEFORE UPDATE ON meeting BEGIN SELECT RAISE(ABORT, 'ro'); END")
        }
        let job = RecoveryJob(
            spool: rig.spool, keys: rig.keys, now: { RecoveryRig.now }, logger: rig.harness.context.logger)
        let report = job.recover(store: store, canResume: false)
        #expect(report.writeFailures == 1)
        #expect(report.incomplete.isEmpty)
        #expect(try store.status(of: meeting.id) == .recording)
        #expect(rig.spoolExists(meeting.uuid))
    }

    // MARK: Ordering, idempotence, expiry

    @Test func recoveryRunsBeforeTheFirstRetentionSweep() async throws {
        let rig = try RecoveryRig(texts: texts)
        let meeting = try rig.seed(.recording, mic: micScript())
        try rig.age(meeting.uuid, to: RecoveryRig.now.addingTimeInterval(-30 * RecoveryRig.day))
        let maintenance = RecordingSpool(existing: [SpoolStorage.name(of: meeting.uuid)])
        let library = rig.library(retention: true, maintenance: maintenance)
        library.open()
        defer { library.close() }

        // The retention pass only offers interrupted meetings: seeing this one proves it was already
        // `incomplete` when the sweep started.
        #expect(await eventually { !maintenance.state.withLock { $0.sweeps }.isEmpty })
        let first = try #require(maintenance.state.withLock { $0.sweeps }.first)
        #expect(first.candidates == [SpoolStorage.name(of: meeting.uuid)])
        #expect(try library.store?.status(of: meeting.id) == .incomplete)
    }

    @Test func aRecoveredSpoolGetsItsFullGracePeriodAndThenExpiresAfterSevenDays() async throws {
        let rig = try RecoveryRig(texts: texts)
        let meeting = try rig.seed(.recording, mic: micScript(), stored: [(.mic, 16_000..<64_000, texts[11]!)])
        // The app was closed for a month after the crash.
        try rig.age(meeting.uuid, to: RecoveryRig.now.addingTimeInterval(-30 * RecoveryRig.day))
        let library = rig.library()
        library.open()
        let store = try #require(library.store)

        #expect(await library.applyRetention() == 0)
        #expect(rig.spoolExists(meeting.uuid))
        #expect(try store.audioState(of: meeting.id) == .spool)

        rig.clock.set(RecoveryRig.now.addingTimeInterval(6 * RecoveryRig.day))
        _ = await library.applyRetention()
        #expect(rig.spoolExists(meeting.uuid))

        rig.clock.set(RecoveryRig.now.addingTimeInterval(8 * RecoveryRig.day))
        _ = await library.applyRetention()
        #expect(!rig.spoolExists(meeting.uuid))
        #expect(try store.audioState(of: meeting.id) == .deleted)
        // The meeting keeps its transcript and stays incomplete.
        #expect(try store.status(of: meeting.id) == .incomplete)
        #expect(try store.segmentCount(meetingID: meeting.id) == 1)
        #expect(try store.incompleteSpoolUUIDs().isEmpty)
        // A deleted spool cannot be finished any more, but the library says so instead of failing.
        library.close()
    }

    @Test func rerunningRecoveryChangesNothing() throws {
        let rig = try RecoveryRig(texts: texts)
        let recording = try rig.seed(.recording, mic: micScript(), stored: [(.mic, 16_000..<64_000, texts[11]!)])
        let failed = try rig.seed(.recording, mic: micScript(), writeSpool: false)
        let library = rig.library(resumer: rig.resumerFactory(mic: micScript()))
        library.open()
        let first = try #require(library.lastRecovery)
        #expect(Set(first.incomplete) == [recording.id])
        #expect(first.failed == [failed.id])
        let stamp = try rig.modificationDate(recording.uuid)
        let before = try #require(try library.store?.recoverableMeetings(statuses: MeetingStatus.allCases))
        library.close()

        rig.clock.set(RecoveryRig.now.addingTimeInterval(3 * RecoveryRig.day))
        library.open()
        #expect(library.lastRecovery == RecoveryReport())
        #expect(try library.store?.recoverableMeetings(statuses: MeetingStatus.allCases) == before)
        // The grace period was not restarted.
        #expect(try rig.modificationDate(recording.uuid) == stamp)
        #expect(rig.spoolExists(recording.uuid))
    }

    // MARK: Keychain

    @Test func aDeletedKeychainItemMakesTheSpoolUnreadableAndItIsDeleted() throws {
        let rig = try RecoveryRig(texts: texts)
        let meeting = try rig.seed(.recording, mic: micScript(), system: systemScript())
        rig.closeSeed()
        try rig.harness.keychain.deleteGenericPassword(service: "app.pounce.meetings", account: "master-key")

        let library = rig.library(resumer: rig.resumerFactory(mic: micScript()))
        library.open()
        #expect(library.status == .ready)
        #expect(library.resetArchive != nil)
        #expect(try library.store?.meetingCount() == 0)
        #expect(!rig.spoolExists(meeting.uuid))
        #expect(library.lastRecovery == RecoveryReport())
        #expect(rig.engine.loads == 0)
    }

    @Test func aKeychainErrorThatIsNotAMissingItemTouchesNoSpool() throws {
        let rig = try RecoveryRig(texts: texts)
        let meeting = try rig.seed(.recording, mic: micScript())
        rig.closeSeed()
        rig.harness.keychain.failReads(with: .accessDenied)
        let library = rig.library()
        library.open()
        #expect(library.status != .ready)
        #expect(rig.spoolExists(meeting.uuid))
        #expect(library.lastRecovery == nil)
        rig.harness.keychain.failReads(with: nil)
        library.open()
        #expect(try library.store?.status(of: meeting.id) == .incomplete)
    }

    // MARK: Logs

    @Test func recoveryNeverLogsTranscriptText() throws {
        var inspected = 0
        for name in [
            "RecoveryJob.swift", "MeetingResumer.swift", "SpoolRecovery.swift", "MeetingsStore+Recovery.swift",
            "MeetingsLibrary.swift",
        ] {
            let source = try String(contentsOf: TestPaths.meetingsSource(named: name), encoding: .utf8)
            let calls = Self.loggerCalls(in: source)
            if name == "RecoveryJob.swift" || name == "MeetingResumer.swift" { #expect(calls.count > 3, "\(name)") }
            for call in calls {
                inspected += 1
                for interpolation in Self.interpolations(in: call) {
                    for forbidden in ["text", "segment", "uuid", "title", "notes", "name"] {
                        #expect(
                            interpolation.range(of: "\\b\(forbidden)\\b", options: .regularExpression) == nil,
                            "\(name): \(call)")
                    }
                }
            }
        }
        #expect(inspected > 10)
    }

    /// Every `logger.<level>( ... )` call, however many lines it spans (parentheses are balanced by hand).
    private static func loggerCalls(in source: String) -> [String] {
        var calls: [String] = []
        var rest = Substring(source)
        while let found = rest.range(of: "logger.") {
            let tail = rest[found.lowerBound...]
            guard let open = tail.firstIndex(of: "(") else { break }
            var depth = 0
            var end = open
            for index in tail[open...].indices {
                if tail[index] == "(" { depth += 1 }
                if tail[index] == ")" {
                    depth -= 1
                    if depth == 0 {
                        end = index
                        break
                    }
                }
            }
            calls.append(String(tail[tail.startIndex...end]))
            rest = tail[tail.index(after: end)...]
        }
        return calls
    }

    private static func interpolations(in call: String) -> [String] {
        var result: [String] = []
        var rest = Substring(call)
        while let start = rest.range(of: "\\(") {
            var depth = 1
            var index = start.upperBound
            while index < rest.endIndex, depth > 0 {
                if rest[index] == "(" { depth += 1 }
                if rest[index] == ")" { depth -= 1 }
                index = rest.index(after: index)
            }
            result.append(String(rest[start.upperBound..<rest.index(before: index)]))
            rest = rest[index...]
        }
        return result
    }
}

extension RecoveryRig {
    var seedStoreForTests: MeetingsStore? { seedStoreAccess }
}
