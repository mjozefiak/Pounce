import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}()

@MainActor
private struct SwitchRig {
    let model: NotesWorkspaceModel
    let meetings: ScriptedNoteSource
    let dictation: ScriptedNoteSource

    init(dictations: Int = 2, pageSize: Int = 100, gate: Gate? = nil) {
        meetings = ScriptedNoteSource(
            "meetings",
            items: [
                Fixtures.summary("meetings", "a", secondsAgo: 10, title: "Pricing sync"),
                Fixtures.summary("meetings", "b", secondsAgo: 30, title: "Standup"),
            ])
        dictation = ScriptedNoteSource(
            "dictation",
            items: (0..<dictations).map {
                Fixtures.summary(
                    "dictation", "s/\($0)", secondsAgo: Double(20 + $0),
                    title: $0 == 0 ? "Buy milk" : "Pricing copy \($0)",
                    kind: .dictation)
            })
        dictation.listGate = gate
        model = NotesWorkspaceModel(
            environment: NotesWorkspaceModel.Environment(
                library: NoteLibrary(box: SourceBox([meetings, dictation])), pasteboard: RecordingPasteboard(),
                saver: ScriptedSaver(), now: { Fixtures.epoch }, calendar: utc, locale: Locale(identifier: "en_US"),
                pageSize: pageSize))
    }
}

@MainActor
@Suite("Explorer: Notes / Dictations switch")
struct NotesCollectionSwitchTests {
    @Test("the explorer starts on Notes and the switch lists the other list; the status line follows")
    func switching() async {
        let rig = SwitchRig()
        await rig.model.refresh()
        #expect(rig.model.collection == .notes)
        #expect(rig.model.statusSummary == "2 notes")
        await rig.model.setCollection(.dictations)
        #expect(rig.model.collection == .dictations)
        #expect(rig.model.rows.map(\.id.key.rawValue) == ["dictation:s/0", "dictation:s/1"])
        #expect(rig.model.total == 2)
        #expect(rig.model.statusSummary == "2 dictations")
        await rig.model.setCollection(.notes)
        #expect(rig.model.rows.map(\.id.key.rawValue) == ["meetings:a", "meetings:b"])
    }

    @Test("a switch drops the old rows at once, so a dictation never shows in the notes list")
    func dropsRowsAtOnce() async {
        let rig = SwitchRig()
        await rig.model.refresh()
        rig.model.prepareCollection(.dictations)
        #expect(rig.model.rows.isEmpty)
        #expect(rig.model.screen == .loading)
    }

    @Test("search follows the list: the same words find different rows, counts and no-results text per list")
    func searchFollowsTheList() async {
        let rig = SwitchRig()
        rig.model.searchText = "pricing"
        await rig.model.runSearch()
        #expect(rig.model.rows.map(\.id.key.rawValue) == ["meetings:a"])
        await rig.model.setCollection(.dictations)
        #expect(rig.model.isSearching)
        #expect(rig.model.rows.map(\.id.key.rawValue) == ["dictation:s/1"])
        #expect(rig.model.total == 1)
        rig.model.searchText = "zzz"
        await rig.model.runSearch()
        #expect(rig.model.screen == .noResults("zzz"))
    }

    @Test("an empty list shows its empty state, per list")
    func emptyStates() async {
        let rig = SwitchRig(dictations: 0)
        await rig.model.refresh()
        #expect(rig.model.screen == .list)
        await rig.model.setCollection(.dictations)
        #expect(rig.model.screen == .empty(recordingOff: false))
        #expect(rig.model.total == 0)
        #expect(rig.model.statusSummary == "0 dictations")
    }

    @Test("a source that fails is reported in its own list only")
    func errorsStayInTheirList() async {
        let rig = SwitchRig()
        rig.dictation.behavior = .throwsError
        await rig.model.refresh()
        #expect(rig.model.unavailable.isEmpty)
        await rig.model.setCollection(.dictations)
        #expect(rig.model.unavailable.map(\.pluginID) == ["dictation"])
    }

    @Test("Dictations pages like Notes and never mixes the lists")
    func paging() async {
        let rig = SwitchRig(dictations: 5, pageSize: 2)
        await rig.model.setCollection(.dictations)
        #expect(rig.model.rows.count == 2)
        #expect(rig.model.hasMore)
        await rig.model.loadMore()
        await rig.model.loadMore()
        #expect(rig.model.rows.map(\.id.key.rawValue) == (0..<5).map { "dictation:s/\($0)" })
        #expect(!rig.model.hasMore)
    }

    @Test("an answer for the list that was left is dropped")
    func staleAnswer() async {
        let gate = Gate()
        let rig = SwitchRig(gate: gate)
        gate.hold(next: 1)
        let slow = Task { await rig.model.setCollection(.dictations) }
        await gate.held.wait()
        await rig.model.setCollection(.notes)
        gate.release()
        await slow.value
        #expect(rig.model.collection == .notes)
        #expect(rig.model.rows.map(\.id.key.rawValue) == ["meetings:a", "meetings:b"])
    }

    @Test("opening a dictation by route (the history's Open in Lintel) switches to Dictations and opens it")
    func routeOpensDictation() async {
        let rig = SwitchRig()
        await rig.model.refresh()
        let key = Fixtures.key("dictation", "s/1")
        #expect(rig.model.handle(NoteRoute.route(for: key)))
        #expect(rig.model.collection == .dictations)
        #expect(rig.model.currentID == .live(key))
        // The list is read in the background; wait for it without polling.
        await waitUntil { rig.model.loadState == .loaded }
        #expect(rig.model.rows.map(\.id.key.rawValue) == ["dictation:s/0", "dictation:s/1"])
        #expect(rig.model.tabs.tabs.first?.kind == .dictation)
        // Opening a meeting goes back to Notes; both tabs stay open.
        #expect(rig.model.handle(NoteRoute.route(for: Fixtures.key("meetings", "a"))))
        #expect(rig.model.collection == .notes)
        #expect(rig.model.tabs.tabs.count == 2)
    }

    @Test("switching lists keeps the open tabs")
    func tabsSurvive() async {
        let rig = SwitchRig()
        await rig.model.refresh()
        rig.model.open(.live(Fixtures.key("meetings", "a")))
        await rig.model.setCollection(.dictations)
        #expect(rig.model.tabs.tabs.count == 1)
        #expect(rig.model.currentID == .live(Fixtures.key("meetings", "a")))
    }
}
