#if DEBUG
import Foundation
import Synchronization

/// DEBUG only, for QA (`plugins.windows.qaDragTrace=<file>`): where the time goes between the first moved event of a
/// drag reaching the engine and the overlay being ordered in. Each stage appends its elapsed time since the first
/// event to one line of the file; release builds contain none of this. The time before `ingest` (the Accessibility
/// notification reaching Lintel) is not Lintel's and is read from the outside (the window's first move).
///
/// One recorder per file. The process-wide `DragTrace` forwards to the recorder the plugin configured from its
/// setting (none unless a QA run names a file), so nothing records in a test that does not ask; the recorder's own
/// tests make instances of their own.
final class DragTraceRecorder: Sendable {
    private struct State {
        var start: ContinuousClock.Instant?
        /// The last time this trace was touched (begin or mark): a trace that has been quiet for `quietGap` belongs
        /// to a drag that ended without the overlay, and the next first move starts a new session.
        var touched: ContinuousClock.Instant?
        var stages: [(String, Duration)] = []
    }

    /// The most stages one trace keeps (a drag that never shows the overlay must not grow it without bound).
    static let stageLimit = 32

    /// How long a trace may be quiet before the next first move starts a new session. The moves of one drag arrive
    /// within tens of milliseconds of each other.
    static let quietGap: Duration = .seconds(1)

    let path: String
    private let state = Mutex(State())
    private let now: @Sendable () -> ContinuousClock.Instant

    init(path: String, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.path = path
        self.now = now
    }

    var isActive: Bool { state.withLock { $0.start != nil } }

    func begin() {
        state.withLock {
            // A trace of the same drag (touched a moment ago) keeps its start; one that has been quiet belongs to a drag
            // that ended without the overlay, and its lines must not merge with the next session's.
            let moment = now()
            if $0.start != nil, let touched = $0.touched, touched.duration(to: moment) < Self.quietGap {
                $0.touched = moment
                return
            }
            $0.start = moment
            $0.touched = moment
            $0.stages = []
        }
    }

    func mark(_ stage: String) {
        state.withLock {
            guard let start = $0.start, $0.stages.count < Self.stageLimit else { return }
            let moment = now()
            $0.touched = moment
            $0.stages.append((stage, start.duration(to: moment)))
        }
    }

    /// The drag ended or was cancelled without the overlay: the trace is dropped.
    func reset() {
        state.withLock {
            $0.start = nil
            $0.touched = nil
            $0.stages = []
        }
    }

    /// The overlay was shown: the line is written and the trace ends.
    func finish() {
        let line: String? = state.withLock { state -> String? in
            guard state.start != nil else { return nil }
            var parts: [String] = []
            for (stage, elapsed) in state.stages {
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                parts.append("\(stage)=\(String(format: "%.1f", seconds * 1000))ms")
            }
            state.start = nil
            state.touched = nil
            state.stages = []
            return parts.joined(separator: " ") + "\n"
        }
        guard let line, let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

enum DragTrace {
    private static let current = Mutex<DragTraceRecorder?>(nil)

    /// Set by the plugin from its setting; `nil` turns tracing off.
    static func configure(path: String?) {
        current.withLock { $0 = path.flatMap { $0.isEmpty ? nil : DragTraceRecorder(path: $0) } }
    }

    private static var recorder: DragTraceRecorder? { current.withLock { $0 } }

    static func begin() { recorder?.begin() }
    static func mark(_ stage: String) { recorder?.mark(stage) }
    static func reset() { recorder?.reset() }
    static func finish() { recorder?.finish() }
}
#endif
