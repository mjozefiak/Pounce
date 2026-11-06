import Foundation
import SwiftUI
import Testing

@testable import LintelKit

/// A plugin written before the Notes workspace: it must compile unchanged and own no note sources.
@MainActor final class PreNotesPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "prenotes", displayName: "Before", symbolName: "1.circle", order: 1)
    init(context: PluginContext) {}
}

struct ScriptedNoteSource: NoteSource {
    let pluginID: PluginID
    func list(matching: NormalizedQuery?, after: NoteCursor?, limit: Int) async throws -> NotePage { NotePage() }
    func exists(_ keys: [NoteKey]) async throws -> Set<NoteKey> { Set(keys) }
    func content(for key: NoteKey) async throws -> NoteContent? { nil }
    func delete(_ key: NoteKey) async throws {}
    func actions(for key: NoteKey) -> [NoteSourceAction] { [] }
    func makeChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

@MainActor final class NoteSourcePlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "withnotes", displayName: "With", symbolName: "2.circle", order: 2)
    init(context: PluginContext) {}
    var noteSources: [any NoteSource] { [ScriptedNoteSource(pluginID: "withnotes")] }
}

/// Overrides only `write(_:options:)`, to check it is reached through `any PasteboardClient`.
@MainActor final class OptionsPasteboard: PasteboardClient {
    private(set) var lastOptions: PasteboardWriteOptions?
    nonisolated init() {}
    var changeCount: Int { 0 }
    func string() -> String? { nil }
    func setString(_ string: String) -> Int { 0 }
    func write(_ items: [PasteboardItem], options: PasteboardWriteOptions) -> Int {
        lastOptions = options
        return 7
    }
}

@Suite @MainActor struct NoteContractTests {
    @Test func pluginDefaultIsEmpty() {
        let plugin: any LintelPlugin = PreNotesPlugin(context: TestContext.make())
        #expect(plugin.noteSources.isEmpty)
    }

    @Test func overrideIsReachedThroughTheExistential() {
        let plugin: any LintelPlugin = NoteSourcePlugin(context: TestContext.make())
        #expect(plugin.noteSources.map(\.pluginID) == ["withnotes"])
    }

    @Test func contextDefaultsDoNothing() async {
        let context = TestContext.make()
        #expect(context.noteSources().isEmpty)
        #expect(context.openNote(NoteKey(pluginID: "meetings", id: "x")) == false)
        var finished = true
        for await _ in context.noteSourcesChanged() { finished = false }
        #expect(finished)
    }

    @Test func keptCopiesDefaultsKeepAndDeleteNothing() async {
        // Step 4.6: a plugin written before it keeps no copies and deletes none (additive, BC section 1).
        let plugin: any LintelPlugin = PreNotesPlugin(context: TestContext.make())
        #expect(await plugin.keptNoteCopyCount(ofOwner: "meetings") == 0)
        #expect(await plugin.deleteKeptNoteCopies(ofOwner: "meetings", ownerErased: false))
        let context = TestContext.make()
        #expect(await context.keptNoteCopies("meetings") == 0)
        #expect(await context.deleteKeptNoteCopies("meetings", true))
    }

    @Test func noteKeyRoundTrips() throws {
        let key = NoteKey(pluginID: "dictation", id: "store:1/42")
        #expect(key.rawValue == "dictation:store:1/42")
        #expect(key.pluginID == "dictation")
        #expect(key.id == "store:1/42")
        let data = try JSONEncoder().encode([key])
        #expect(String(decoding: data, as: UTF8.self) == "[\"dictation:store:1\\/42\"]")
        #expect(try JSONDecoder().decode([NoteKey].self, from: data) == [key])
    }

    @Test func malformedNoteKeysDoNotDecode() {
        for raw in ["nocolon", ":x", "x:"] {
            let data = Data("[\"\(raw)\"]".utf8)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode([NoteKey].self, from: data) }
        }
    }

    @Test func unknownOpenSetValuesDecode() throws {
        let kinds = try JSONDecoder().decode([NoteKind].self, from: Data("[\"meeting\",\"whiteboard\"]".utf8))
        #expect(kinds == [.meeting, NoteKind(rawValue: "whiteboard")])
        let authors = try JSONDecoder().decode([NoteAuthor].self, from: Data("[\"human\",\"robot\"]".utf8))
        #expect(authors == [.human, NoteAuthor(rawValue: "robot")])
        #expect(try JSONEncoder().encode(NoteKind.manual) == Data("\"manual\"".utf8))
    }

    @Test func publicInitsHaveDefaults() {
        let key = NoteKey(pluginID: "notes", id: "1")
        let summary = NoteSummary(id: key, kind: .manual, startedAt: Date(timeIntervalSince1970: 0))
        #expect(summary.state == .ready && summary.matches.isEmpty && !summary.titleMatched)
        let content = NoteContent(summary: summary)
        #expect(content.layers.isEmpty && content.speakers.isEmpty && content.details.isEmpty)
        #expect(NotePage().items.isEmpty && NotePage().next == nil)
        #expect(NoteBlockProvenance(blockIndex: 2).quoteTimesMs.isEmpty)
        #expect(NoteSpeaker(id: "s1", name: "Ann").isSelf == false)
        let action = NoteSourceAction(id: "a", title: "Do", symbolName: "star") {}
        #expect(action.isDestructive == false)
    }

    @Test func pasteboardOptionsOverrideIsReachedThroughTheExistential() {
        let pasteboard = OptionsPasteboard()
        let client: any PasteboardClient = pasteboard
        #expect(client.write([], options: .currentHostOnly) == 7)
        #expect(pasteboard.lastOptions == .currentHostOnly)
    }

    @Test func pasteboardOptionsDefaultCallsPlainWrite() {
        let pasteboard = StringOnlyPasteboard()
        let client: any PasteboardClient = pasteboard
        let item = PasteboardItem(representations: [
            PasteboardRepresentation(type: PasteboardRepresentation.plainTextType, data: Data("hi".utf8))
        ])
        client.write([item], options: .currentHostOnly)
        #expect(pasteboard.string() == "hi")
    }
}
