import AppKit
import Foundation
import PounceKit
import SwiftUI
import Synchronization
import Testing

@testable import PounceApp

/// Counts every call, so a test can prove a list mode never touches `ranking.sqlite`.
actor SpyUsageRecorder: UsageRecorder {
    private(set) var calls = 0

    func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws { calls += 1 }

    func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] {
        calls += 1
        return [:]
    }
}

/// A list mode source with fixed notes in a fixed order (not alphabetical), filtered by the first letter.
nonisolated struct NotesSource: PanelModeSource {
    static let notes = ["Zebra note", "apple note", "Mango note"]
    let log: ActionLog

    func search(_ query: NormalizedQuery, filter: PanelModeFilter.ID?, limit: Int) async throws -> [Candidate] {
        log.record("search \(query.raw) filter=\(filter ?? "-")")
        return Self.notes
            .filter { query.isEmpty || $0.lowercased().contains(query.normalized) }
            .filter { filter == nil || $0.lowercased().hasPrefix(filter ?? "") }
            .map {
                Candidate(
                    itemKey: ItemKey(pluginID: "notes", key: $0),
                    title: $0,
                    icon: .symbol("note"),
                    match: MatchResult(tier: .fuzzy, score: 0)
                )
            }
    }

    func actions(for candidate: Candidate) -> [ResultAction] {
        let log = log
        return [
            ResultAction(id: "paste", title: "Paste", symbolName: "doc.on.clipboard") { _ in
                log.record("paste \(candidate.title)")
            },
            ResultAction(
                id: "delete",
                title: "Delete",
                symbolName: "trash",
                shortcut: KeyShortcut(key: "x", modifiers: .control),
                keepsPanelOpen: true
            ) { _ in
                log.record("delete \(candidate.title)")
            },
        ]
    }
}

func notesMode(log: ActionLog, opened: ActionLog? = nil) -> PanelMode {
    PanelMode(
        id: "notes",
        title: "Notes",
        symbolName: "note",
        source: NotesSource(log: log),
        filters: [
            PanelModeFilter(id: "z", title: "Z", symbolName: "z.circle"),
            PanelModeFilter(id: "a", title: "A", symbolName: "a.circle"),
        ],
        makePreview: { candidate in AnyView(Text(candidate.title)) },
        makeEmptyView: { AnyView(Text("Nothing yet")) },
        willOpen: { opened?.record("open") }
    )
}

@Suite struct ListModeSearchTests {
    @Test func keepsTheSourceOrderAndNeverTouchesUsage() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([])
        let spy = SpyUsageRecorder()
        let coordinator = SearchCoordinator(host: host, usage: spy)
        let log = ActionLog()

        let all = try #require(await coordinator.search(mode: notesMode(log: log), raw: "note", filter: nil))
        #expect(all.items.map(\.candidate.title) == NotesSource.notes)
        #expect(all.sections.count == 1)
        #expect(all.items.first?.kind == "Notes")

        let filtered = try #require(await coordinator.search(mode: notesMode(log: log), raw: "", filter: "a"))
        #expect(filtered.items.map(\.candidate.title) == ["apple note"])
        #expect(log.all.contains("search  filter=a"))
        #expect(await spy.calls == 0)
    }
}

@Suite struct ListModePanelTests {
    func makeModel(log: ActionLog, opened: ActionLog) async throws -> (PanelModel, FakePresenter) {
        let test = try TestEnvironment()
        let coordinator = SearchCoordinator(host: test.makeHost([]), usage: SpyUsageRecorder())
        let model = PanelModel { _ in .empty }
        let mode = notesMode(log: log, opened: opened)
        model.panelMode = { $0 == "notes" ? mode : nil }
        model.modeSearch = { mode, text, filter in await coordinator.search(mode: mode, raw: text, filter: filter) }
        let presenter = FakePresenter()
        model.presenter = presenter
        model.panelPresenter = presenter
        model.announce = { _ in }
        test.tearDown()
        return (model, presenter)
    }

    @Test func opensAtFullHeightAndSearchesTheModeSource() async throws {
        let log = ActionLog()
        let opened = ActionLog()
        let (model, _) = try await makeModel(log: log, opened: opened)
        model.show(mode: .plugin("notes"))
        await model.waitForSearch()
        #expect(opened.all == ["open"])
        #expect(model.preferredHeight == PanelModel.Metrics.maximumHeight)
        #expect(model.currentListMode?.id == "notes")
        #expect(model.results.items.map(\.candidate.title) == NotesSource.notes)
        #expect(!model.showsModeEmptyState)
    }

    @Test func commandNumbersToggleFilters() async throws {
        let log = ActionLog()
        let (model, _) = try await makeModel(log: log, opened: ActionLog())
        model.show(mode: .plugin("notes"))
        await model.waitForSearch()

        #expect(model.toggleFilter(at: 1))
        await model.waitForSearch()
        #expect(model.modeFilter == "a")
        #expect(model.results.items.map(\.candidate.title) == ["apple note"])

        #expect(model.toggleFilter(at: 1))
        await model.waitForSearch()
        #expect(model.modeFilter == nil)
        #expect(model.results.items.count == 3)
        #expect(!model.toggleFilter(at: 5))
    }

    @Test func filtersOnlyExistInListModes() async throws {
        let (model, _) = try await makeModel(log: ActionLog(), opened: ActionLog())
        model.show()
        #expect(!model.toggleFilter(at: 0))
    }

    @Test func anActionThatKeepsThePanelOpenRunsWithoutHidingIt() async throws {
        let log = ActionLog()
        let (model, presenter) = try await makeModel(log: log, opened: ActionLog())
        model.show(mode: .plugin("notes"))
        await model.waitForSearch()
        model.moveSelection(by: 1)
        #expect(model.perform(shortcut: KeyShortcut(key: "x", modifiers: .control)))
        await model.waitForAction()
        #expect(log.all.contains("delete apple note"))
        #expect(model.isVisible)
        #expect(presenter.dismissed == 0)

        model.performPrimary()
        await model.waitForAction()
        #expect(log.all.contains("paste apple note"))
        #expect(!model.isVisible)
    }

    @Test func aDeletedRowLeavesTheSelectionAtItsPosition() async throws {
        let (model, _) = try await makeModel(log: ActionLog(), opened: ActionLog())
        model.show(mode: .plugin("notes"))
        await model.waitForSearch()
        model.moveSelection(by: 1)
        let selected = try #require(model.selectedItem)
        let remaining = model.results.items.filter { $0.id != selected.id }
        model.apply(
            SearchResults(
                query: model.results.query,
                sections: [
                    ResultSection(id: "s", title: "Notes", symbolName: "note", kind: .results, items: remaining)
                ]),
            keeping: selected.id
        )
        #expect(model.selectedIndex == 1)
        #expect(model.selectedItem?.candidate.title == "Mango note")
    }

    @Test func switchingModesStartsWithAnEmptyQuery() async throws {
        let (model, _) = try await makeModel(log: ActionLog(), opened: ActionLog())
        model.show()
        model.updateQuery("app")
        model.show(mode: .plugin("notes"))
        await model.waitForSearch()
        #expect(model.query.isEmpty)
        #expect(model.mode == .plugin("notes"))
        model.hide()
        #expect(model.mode == .search)
        #expect(model.modeFilter == nil)
    }
}

@Suite struct ConfirmationHUDTests {
    @Test func showsAndHidesTheMessage() {
        let hud = ConfirmationHUD()
        hud.show("Copied", near: NSRect(x: -20_000, y: -20_000, width: 10, height: 10))
        #expect(hud.message == "Copied")
        hud.hide()
        #expect(hud.message == nil)
    }
}

@Suite struct ListModeViewTests {
    @Test func rendersTheListThePreviewAndTheFilters() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let coordinator = SearchCoordinator(host: test.makeHost([]), usage: SpyUsageRecorder())
        let model = PanelModel { _ in .empty }
        let mode = notesMode(log: ActionLog())
        model.panelMode = { _ in mode }
        model.modeSearch = { mode, text, filter in await coordinator.search(mode: mode, raw: text, filter: filter) }
        model.announce = { _ in }
        model.show(mode: .plugin("notes"))
        await model.waitForSearch()
        let view = LauncherView(model: model, icons: IconCache(loader: { _ in nil }), onFieldCreated: { _ in })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: PanelModel.Metrics.width, height: model.preferredHeight)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height > 0)
        #expect(model.selectedItem?.candidate.title == "Zebra note")
    }
}
