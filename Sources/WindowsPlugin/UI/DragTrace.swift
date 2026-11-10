#if DEBUG
import Foundation
import Synchronization

/// DEBUG only, for QA (`plugins.windows.qaDragTrace=<file>`): where the time goes between the first moved event of a
/// drag reaching the engine and the overlay being ordered in. Each stage appends its elapsed time since the first
/// event to one line of the file; release builds contain none of this. The time before `ingest` (the Accessibility
/// notification reaching Lintel) is not Lintel's and is read from the outside (the window's first move).
enum DragTrace {
    private struct State {
        var path: String?
        var start: ContinuousClock.Instant?
        var stages: [(String, Duration)] = []
    }

    private static let state = Mutex(State())

    /// Set by the plugin from its setting; `nil` turns tracing off.
    static func configure(path: String?) {
        state.withLock { $0.path = path?.isEmpty == true ? nil : path }
    }

    /// The first moved event of a drag reaches the engine: a new trace starts.
    static func begin() {
        state.withLock {
            guard $0.path != nil else { return }
            // A trace that never reached the overlay (no drag followed) is stale after a few seconds: start again.
            if let start = $0.start, start.duration(to: .now) < .seconds(5) { return }
            $0.start = .now
            $0.stages = []
        }
    }

    /// The most stages one trace keeps (a drag that never shows the overlay must not grow it without bound).
    static let stageLimit = 32

    static func mark(_ stage: String) {
        state.withLock {
            guard let start = $0.start, $0.stages.count < stageLimit else { return }
            $0.stages.append((stage, start.duration(to: .now)))
        }
    }

    /// The drag ended or was cancelled without the overlay: the trace is dropped.
    static func reset() {
        state.withLock {
            $0.start = nil
            $0.stages = []
        }
    }

    /// The overlay was shown: the line is written and the trace ends.
    static func finish() {
        let line: (path: String, text: String)? = state.withLock { state -> (path: String, text: String)? in
            guard let path = state.path, state.start != nil else { return nil }
            var parts: [String] = []
            for (stage, elapsed) in state.stages {
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                parts.append("\(stage)=\(String(format: "%.1f", seconds * 1000))ms")
            }
            state.start = nil
            state.stages = []
            return (path, parts.joined(separator: " ") + "\n")
        }
        guard let line, let data = line.text.data(using: .utf8) else { return }
        let path = line.path
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
#endif
