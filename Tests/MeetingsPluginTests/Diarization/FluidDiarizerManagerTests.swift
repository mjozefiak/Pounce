import FluidAudio
import Foundation
import Synchronization
import Testing

@testable import MeetingsPlugin

/// Kept apart from `DiarizerTests`: this file imports FluidAudio, whose `AudioSampleSource` would hide the
/// plugin's own in a file that uses both.
@Suite struct FluidDiarizerManagerTests {
    @Test func releaseDropsTheLoadedManager() async throws {
        let loads = Mutex(0)
        let diarizer = FluidDiarizer(
            modelFolder: URL(filePath: "/nonexistent"),
            makeManager: { _ in
                loads.withLock { $0 += 1 }
                return OfflineDiarizerManager(config: .default)
            })
        #expect(await !diarizer.isLoaded)
        try await diarizer.loadIfNeeded()
        try await diarizer.loadIfNeeded()
        #expect(await diarizer.isLoaded)
        #expect(loads.withLock { $0 } == 1)
        await diarizer.release()
        #expect(await !diarizer.isLoaded)
        // Loading again after a release builds a new manager.
        try await diarizer.loadIfNeeded()
        #expect(loads.withLock { $0 } == 2)
        await diarizer.release()
    }
}
