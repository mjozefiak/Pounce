#if DEBUG
import Foundation
import Testing

@testable import WindowsPlugin

/// The DEBUG-only timing trace for QA N2 (`plugins.windows.qaDragTrace`): one line per drag with the elapsed time at
/// each stage. Serialized because the trace is one process-wide recorder.
@Suite(.timeLimit(.minutes(1)), .serialized) struct DragTraceTests {
    @Test func aTraceIsWrittenOnceWithEveryStageAndOffMeansNothingIsWritten() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "drag-trace-\(UUID().uuidString).txt").path
        defer {
            DragTrace.configure(path: nil)
            try? FileManager.default.removeItem(atPath: path)
        }
        // Off: nothing is recorded or written.
        DragTrace.configure(path: nil)
        DragTrace.begin()
        DragTrace.mark("ingest")
        DragTrace.finish()
        #expect(!FileManager.default.fileExists(atPath: path))

        DragTrace.configure(path: path)
        DragTrace.begin()
        DragTrace.mark("ingest")
        DragTrace.mark("read")
        DragTrace.mark("overlayShown")
        DragTrace.finish()
        // A second begin() without a finish keeps the first start; a finish without a begin writes nothing.
        DragTrace.finish()
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines[0].contains("ingest=") && lines[0].contains("read=") && lines[0].contains("overlayShown="))
    }
}
#endif
