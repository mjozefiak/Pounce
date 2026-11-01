import Foundation
import SwiftUI
import Synchronization
import Testing

@testable import PounceKit

/// A pasteboard that only implements the Phase 0 requirements, so the Phase 2 defaults are exercised.
@MainActor final class StringOnlyPasteboard: PasteboardClient {
    private(set) var value: String?
    private(set) var count = 0

    nonisolated init() {}

    var changeCount: Int { count }
    func string() -> String? { value }
    func setString(_ string: String) -> Int {
        value = string
        count += 1
        return count
    }
}

@Suite @MainActor struct PasteboardDefaultsTests {
    @Test func readsAndWritesThePlainTextRepresentation() throws {
        let pasteboard = StringOnlyPasteboard()
        #expect(pasteboard.types().isEmpty)
        #expect(pasteboard.readContents(maxBytes: 100) == nil)
        #expect(pasteboard.accessBehavior == .alwaysAllow)

        let item = PasteboardItem(representations: [
            PasteboardRepresentation(type: "public.rtf", data: Data("{\\rtf1}".utf8)),
            PasteboardRepresentation(type: PasteboardRepresentation.plainTextType, data: Data("fake text".utf8)),
        ])
        let changeCount = pasteboard.write([item])
        #expect(changeCount == 1)
        #expect(pasteboard.string() == "fake text")
        #expect(pasteboard.types() == [PasteboardRepresentation.plainTextType])

        let contents = try #require(pasteboard.readContents(maxBytes: 100))
        #expect(contents.changeCount == 1)
        #expect(contents.items.first?.data(for: PasteboardRepresentation.plainTextType) == Data("fake text".utf8))
        #expect(contents.byteCount == 9)
        #expect(!contents.exceedsLimit)
    }

    @Test func aReadOverTheLimitIsMarkedIncomplete() throws {
        let pasteboard = StringOnlyPasteboard()
        pasteboard.setString(String(repeating: "x", count: 50))
        let contents = try #require(pasteboard.readContents(maxBytes: 10))
        #expect(contents.exceedsLimit)
        #expect(contents.items.isEmpty)
    }
}

@Suite @MainActor struct WorkspaceDefaultsTests {
    struct PIDOnlyWorkspace: WorkspaceClient {
        @MainActor var frontmostApplicationPID: pid_t? { 42 }
        @MainActor func open(_ url: URL) async throws {}
        @MainActor func revealInFinder(_ urls: [URL]) {}
    }

    @Test func defaultsKnowOnlyTheProcessIdentifier() async {
        let workspace = PIDOnlyWorkspace()
        #expect(workspace.frontmostApplication == RunningApplication(processIdentifier: 42))
        #expect(workspace.runningApplication(processIdentifier: 7)?.processIdentifier == 7)
        var activations = 0
        for await _ in workspace.sessionActivations() {
            activations += 1
        }
        #expect(activations == 0)
    }
}

@Suite @MainActor struct PanelModeTests {
    struct EchoSource: PanelModeSource {
        func search(_ query: NormalizedQuery, filter: PanelModeFilter.ID?, limit: Int) async throws -> [Candidate] {
            [
                Candidate(
                    itemKey: ItemKey(pluginID: "echo", key: filter ?? "all"),
                    title: query.raw,
                    icon: .symbol("circle"),
                    match: MatchResult(tier: .exact, score: 1)
                )
            ]
        }
    }

    @Test func aViewModeHasNoSource() {
        let mode = PanelMode(id: "view", title: "View", symbolName: "eye") { AnyView(EmptyView()) }
        #expect(!mode.isListMode)
        #expect(mode.filters.isEmpty)
        #expect(mode.makePreview == nil)
        #expect(mode.willOpen == nil)
    }

    @Test func aListModeCarriesItsSourceAndFilters() async throws {
        let mode = PanelMode(
            id: "echo",
            title: "Echo",
            symbolName: "repeat",
            source: EchoSource(),
            filters: [PanelModeFilter(id: "text", title: "Text", symbolName: "doc.plaintext")]
        )
        #expect(mode.isListMode)
        #expect(mode.filters.map(\.id) == ["text"])
        let source = try #require(mode.source)
        let found = try await source.search(NormalizedQuery(raw: "hi", normalized: "hi"), filter: "text", limit: 5)
        #expect(found.first?.itemKey.rawValue == "echo:text")
        #expect(source.actions(for: try #require(found.first)).isEmpty)
    }

    @Test func actionsHideThePanelUnlessTheySayOtherwise() {
        let hides = ResultAction(id: "a", title: "A", symbolName: "a.circle") { _ in }
        let stays = ResultAction(id: "b", title: "B", symbolName: "b.circle", keepsPanelOpen: true) { _ in }
        #expect(!hides.keepsPanelOpen)
        #expect(stays.keepsPanelOpen)
    }

    @Test func theDefaultShortcutRecorderShowsNothing() {
        let context = TestContext.make()
        _ = context.makeShortcutRecorder("anything")
        #expect(context.storageDirectory.lastPathComponent == "pounce-kit-tests")
    }
}
