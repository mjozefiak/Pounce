#if DEBUG
import Foundation
import Synchronization
import Testing

@testable import WindowsPlugin

/// The DEBUG-only timing trace for QA N2 (`plugins.windows.qaDragTrace`): one line per drag with the elapsed time at
/// each stage. Each test makes a recorder of its own, so nothing here depends on, or disturbs, the process-wide one
/// that engine tests would reach (it records nothing unless a QA run names a file).
@Suite(.timeLimit(.minutes(1))) struct DragTraceTests {
    private func path() -> String {
        FileManager.default.temporaryDirectory.appending(path: "drag-trace-\(UUID().uuidString).txt").path
    }

    @Test func aTraceIsWrittenOnceWithEveryStage() throws {
        let path = path()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let recorder = DragTraceRecorder(path: path)
        recorder.begin()
        recorder.mark("ingest")
        recorder.mark("read")
        recorder.mark("overlayShown")
        recorder.finish()
        // A finish without a begin writes nothing more.
        recorder.finish()
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines[0].contains("ingest=") && lines[0].contains("read=") && lines[0].contains("overlayShown="))
    }

    @Test func aDragThatNeverShowsTheOverlayCannotGrowTheTraceAndAResetStartsClean() throws {
        let path = path()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let recorder = DragTraceRecorder(path: path)
        recorder.begin()
        for index in 0..<(DragTraceRecorder.stageLimit * 4) { recorder.mark("stage\(index)") }
        recorder.reset()
        #expect(!recorder.isActive)
        recorder.begin()
        recorder.mark("ingest")
        recorder.mark("overlayShown")
        recorder.finish()
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines[0].split(separator: " ").count == 2)
        recorder.begin()
        for index in 0..<(DragTraceRecorder.stageLimit * 4) { recorder.mark("s\(index)") }
        recorder.finish()
        let again = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(again.count == 2)
        #expect(again[1].split(separator: " ").count == DragTraceRecorder.stageLimit)
    }

    @Test func theProcessWideTraceRecordsNothingWithoutAFile() {
        DragTrace.configure(path: nil)
        DragTrace.begin()
        DragTrace.mark("ingest")
        DragTrace.finish()
    }

    /// QA round 4, D10: a session that never reached the overlay and was not reset left its start behind, so the next
    /// session's lines carried the old session's stages and times. The next first move after a quiet gap starts again;
    /// the moves of one drag keep their start.
    @Test func aQuietUnfinishedSessionDoesNotMergeIntoTheNextOne() throws {
        let path = path()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let base = ContinuousClock.Instant.now
        let offset = Mutex<Duration>(.zero)
        let recorder = DragTraceRecorder(path: path, now: { base.advanced(by: offset.withLock { $0 }) })
        recorder.begin()
        recorder.mark("ingest")
        // The same drag keeps sending moves within the gap: its start stays.
        offset.withLock { $0 = .milliseconds(40) }
        recorder.begin()
        recorder.mark("ingest")
        // The drag ended without the overlay and nobody reset the trace; ten seconds later a new drag begins.
        offset.withLock { $0 = .seconds(10) }
        recorder.begin()
        recorder.mark("ingest")
        offset.withLock { $0 = .seconds(10) + .milliseconds(30) }
        recorder.mark("overlayShown")
        recorder.finish()
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let parts = lines[0].split(separator: " ")
        #expect(parts.count == 2, "\(lines[0])")
        #expect(parts[0] == "ingest=0.0ms")
        #expect(parts[1] == "overlayShown=30.0ms")
    }
}
#endif
