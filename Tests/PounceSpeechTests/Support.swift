import Foundation
import Synchronization

@testable import PounceSpeech

/// A temporary directory removed when the test object is released.
final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "pounce-speech-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Answers "segment N" and counts loads, calls and unloads.
final class FakeEngine: SpeechEngine, @unchecked Sendable {
    struct State {
        var loaded = false
        var calls = 0
        var unloads = 0
    }

    let state = Mutex(State())

    var isLoaded: Bool { state.withLock { $0.loaded } }

    func load(modelFolder: URL) async throws {
        state.withLock { $0.loaded = true }
    }

    func transcribe(_ samples: [Float]) async throws -> TranscriptSegment {
        let key = Int((samples.first ?? 0) * 100 + 0.5)
        state.withLock { $0.calls += 1 }
        return TranscriptSegment(text: "segment \(key)")
    }

    func unload() async {
        state.withLock {
            $0.loaded = false
            $0.unloads += 1
        }
    }
}
