import Foundation
import LintelKit
import SwiftUI
import Testing

@testable import LintelApp

/// A source that lists nothing; only its id matters here.
private struct IdleNoteSource: NoteSource {
    let pluginID: PluginID
    func list(matching: NormalizedQuery?, after: NoteCursor?, limit: Int) async throws -> NotePage { NotePage() }
    func exists(_ keys: [NoteKey]) async throws -> Set<NoteKey> { [] }
    func content(for key: NoteKey) async throws -> NoteContent? { nil }
    func delete(_ key: NoteKey) async throws {}
    func actions(for key: NoteKey) -> [NoteSourceAction] { [] }
    func makeChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// Owns the id `noted` and hands out a source with its own id, a second one with the same id and one with a
/// stranger's.
private final class NotedPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "noted", displayName: "Noted", symbolName: "note", order: 1)
    init(context: PluginContext) {}
    var noteSources: [any NoteSource] {
        [
            IdleNoteSource(pluginID: "noted"), IdleNoteSource(pluginID: "noted"), IdleNoteSource(pluginID: "stranger"),
        ]
    }
}

/// Spec `2026-11-04-notes-workspace`, step 3.2: what the shell hands the Notes section through the plugin
/// context (`noteSources`, `noteSourcesChanged`, `openNote`).
@MainActor @Suite struct NoteRoutingTests {
    @Test func theSourcesOfActivePluginsAreHandedOverAndMismatchedOnesDropped() async throws {
        let rig = try TestEnvironment()
        defer { rig.tearDown() }
        let host = rig.makeHost([NotedPlugin.self])
        await host.start()
        var reports: [String] = []
        let sources = AppCoordinator.activeNoteSources(host) { reports.append($0) }
        #expect(sources.map(\.pluginID) == ["noted"])
        #expect(reports.count == 2)
        #expect(reports.contains { $0.contains("does not match") })
        #expect(reports.contains { $0.contains("duplicate") })
        // A switched-off plugin hands out nothing.
        await host.setEnabled(false, for: "noted")
        #expect(AppCoordinator.activeNoteSources(host).isEmpty)
        await host.stop()
    }

    @Test func theRelayYieldsToEveryStreamWhenTheSetOfSourcesChanges() async {
        let relay = NoteSourcesRelay()
        var first = relay.changes().makeAsyncIterator()
        var second = relay.changes().makeAsyncIterator()
        relay.signalChanged()
        #expect(await first.next() != nil)
        #expect(await second.next() != nil)
    }

    @Test func aStreamThatIsDroppedStopsReceiving() async {
        let relay = NoteSourcesRelay()
        do {
            var dropped = relay.changes().makeAsyncIterator()
            _ = dropped
        }
        // Signalling with no consumer is harmless, and a new stream starts clean.
        relay.signalChanged()
        var fresh = relay.changes().makeAsyncIterator()
        relay.signalChanged()
        #expect(await fresh.next() != nil)
    }

    @Test func aRouteNoSectionHandlesReturnsFalseSoThePluginKeepsItsOwnWindow() {
        let relay = NoteSourcesRelay()
        #expect(!relay.openNote(WorkspaceRoute(kind: "openNote", id: "meetings:a")))
        relay.openNote = { $0.kind == "openNote" }
        #expect(relay.openNote(WorkspaceRoute(kind: "openNote", id: "meetings:a")))
    }
}
