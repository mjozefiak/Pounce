import Foundation
import LintelKit
import Synchronization

/// What `PluginContext.noteSources`, `noteSourcesChanged` and `openNote` reach before the coordinator exists
/// (plugin contexts are built while the host is). The coordinator sets the two handlers once the host is built
/// and calls `signalChanged()` whenever a plugin is switched on or off.
///
/// `sources` hands out only the active plugins' sources and drops (and logs once) a source whose `pluginID`
/// differs from its plugin's id, and any later source of the same id (`NoteSourceSet` in `NotesPlugin` also
/// guards this; the shell does it first, as the contract says).
final class NoteSourcesRelay: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    /// The active plugins' sources. Set by the coordinator.
    @MainActor var sources: () -> [any NoteSource] = { [] }
    /// An `openNote` request: `true` when a section handled it. Set by the coordinator.
    @MainActor var openNote: (WorkspaceRoute) -> Bool = { _ in false }
    /// What Notes keeps of a plugin's recordings (edited or commented copies) and its removal. Set by the coordinator.
    @MainActor var keptCopies: (PluginID) async -> Int = { _ in 0 }
    @MainActor var deleteKeptCopies: (PluginID, Bool) async -> Bool = { _, _ in true }

    /// One stream per call, finished when its consumer stops.
    nonisolated func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    nonisolated func signalChanged() {
        let all = continuations.withLock { Array($0.values) }
        for continuation in all { continuation.yield() }
    }
}
