import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

/// Answers of a source that arrive late: the model keeps the newest, and a source that does not answer in its
/// budget costs only its own tab. Time moves only through the `ManualClock`; nothing sleeps or polls.
@MainActor
@Suite("Notes workspace: late and slow answers", .timeLimit(.minutes(1)))
struct NotesWorkspaceRaceTests {
    private let key = Fixtures.key("meetings", "a")

    private func content(_ key: NoteKey, text: String) -> NoteContent {
        NoteContent(
            summary: Fixtures.summary(
                "meetings", key.rawValue.replacingOccurrences(of: "meetings:", with: ""), secondsAgo: 1),
            layers: [NoteLayer(id: "notes", author: .agent, markdown: text, version: "1")], speakers: [], details: [])
    }

    private func rig(
        items: Int = 1, pageSize: Int = 100, saver: any NoteFileSaving = ScriptedSaver()
    ) -> (NotesWorkspaceModel, ScriptedNoteSource, ManualClock) {
        let source = ScriptedNoteSource(
            "meetings", items: (0..<items).map { Fixtures.summary("meetings", "m\($0)", secondsAgo: Double($0 + 1)) })
        let clock = ManualClock()
        let model = NotesWorkspaceModel(
            environment: NotesWorkspaceModel.Environment(
                library: NoteLibrary(box: SourceBox([source]), clock: clock), pasteboard: RecordingPasteboard(),
                saver: saver, now: { Fixtures.epoch }, pageSize: pageSize, clock: clock))
        return (model, source, clock)
    }

    @Test("an older read of a note cannot overwrite the answer of a newer one")
    func staleContentIsDropped() async throws {
        let (model, source, _) = rig()
        let id = NoteItemID.live(key)
        model.open(id)
        let document = try #require(model.documents[id])
        source.contents[key] = content(key, text: "old")
        let gate = Gate()
        source.contentGate = gate
        gate.hold(next: 1)
        let older = Task { await model.loadContent(id) }
        await gate.held.wait(atLeast: 1)

        source.contents[key] = content(key, text: "new")
        await model.loadContent(id)
        #expect(document.selectedLayer?.markdown == "new")

        gate.release()
        await older.value
        #expect(document.selectedLayer?.markdown == "new")
    }

    @Test("an answer for a tab that was closed meanwhile is dropped")
    func closedTab() async throws {
        let (model, source, _) = rig()
        let id = NoteItemID.live(key)
        model.open(id)
        let document = try #require(model.documents[id])
        source.contents[key] = content(key, text: "text")
        let gate = Gate()
        source.contentGate = gate
        gate.hold(next: 1)
        let read = Task { await model.loadContent(id) }
        await gate.held.wait(atLeast: 1)
        model.close(id)
        gate.release()
        await read.value
        #expect(document.phase == .loading)
        #expect(model.documents[id] == nil)
    }

    @Test("a source that does not answer within the budget leaves its tab unavailable")
    func contentBudget() async throws {
        let (model, source, clock) = rig()
        let id = NoteItemID.live(key)
        model.open(id)
        source.contentBehavior = .hangs
        let read = Task { await model.loadContent(id) }
        await clock.waitForSleeps(1)
        clock.advance(by: .milliseconds(150))
        await read.value
        #expect(model.documents[id]?.phase == .unavailable)
    }

    @Test("a refresh reads every open tab on its own: a hanging note does not hold up the others")
    func tabsAreIndependent() async throws {
        let hanging = ScriptedNoteSource("meetings", items: [Fixtures.summary("meetings", "a", secondsAgo: 1)])
        let answering = ScriptedNoteSource("dictation", items: [Fixtures.summary("dictation", "b", secondsAgo: 2)])
        hanging.contentBehavior = .hangs
        let answeringKey = Fixtures.key("dictation", "b")
        answering.contents[answeringKey] = content(answeringKey, text: "fast")
        let clock = ManualClock()
        let model = NotesWorkspaceModel(
            environment: NotesWorkspaceModel.Environment(
                library: NoteLibrary(box: SourceBox([hanging, answering]), clock: clock),
                pasteboard: RecordingPasteboard(), saver: ScriptedSaver(), now: { Fixtures.epoch }, clock: clock))
        let slow = NoteItemID.live(key)
        let fast = NoteItemID.live(answeringKey)
        model.open(slow)
        model.open(fast)

        // Two listings and two content reads each set a deadline.
        let base = clock.sleepCalls
        let refreshing = Task { await model.refresh() }
        await waitUntil { model.documents[fast]?.phase == .loaded }
        #expect(model.documents[slow]?.phase == .loading)

        await clock.waitForSleeps(base + 4)
        clock.advance(by: .milliseconds(150))
        await refreshing.value
        #expect(model.documents[slow]?.phase == .unavailable)
        #expect(model.documents[fast]?.phase == .loaded)
    }

    @Test("a page that arrives after a newer refresh does not overwrite it")
    func staleLoadMore() async throws {
        let (model, source, _) = rig(items: 5, pageSize: 2)
        await model.refresh()
        #expect(model.rows.count == 2)
        #expect(model.hasMore)
        let gate = Gate()
        source.listGate = gate
        gate.hold(next: 1)
        let more = Task { await model.loadMore() }
        await gate.held.wait(atLeast: 1)

        source.items = Array(source.items.prefix(2))
        await model.refresh()
        #expect(model.rows.count == 2)
        #expect(!model.hasMore)
        let token = model.pageToken

        gate.release()
        await more.value
        #expect(model.rows.map(\.id.key.rawValue) == ["meetings:m0", "meetings:m1"])
        #expect(model.total == 2)
        #expect(!model.hasMore)
        #expect(model.pageToken == token)
    }

    @Test("every page that comes in changes the token the explorer's sentinel is keyed on")
    func pageToken() async {
        let (model, _, _) = rig(items: 5, pageSize: 2)
        await model.refresh()
        let first = model.pageToken
        await model.loadMore()
        #expect(model.pageToken != first)
        #expect(model.rows.count == 4)
        let second = model.pageToken
        await model.loadMore()
        #expect(model.pageToken != second)
        #expect(model.rows.count == 5)
        #expect(!model.hasMore)
    }

    @Test("a second Save .md while the panel is open does nothing")
    func oneSavePanel() async throws {
        let saver = GatedSaver()
        let (model, source, _) = rig(saver: saver)
        let id = NoteItemID.live(key)
        source.contents[key] = content(key, text: "text")
        model.open(id)
        await model.loadContent(id)
        let first = Task { await model.saveMarkdown() }
        await saver.entered.wait(atLeast: 1)
        await model.saveMarkdown()
        saver.finish()
        await first.value
        #expect(saver.calls == 1)
    }
}

/// A saver whose panel stays open until the test finishes it.
@MainActor
final class GatedSaver: NoteFileSaving {
    let entered = CountLatch()
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func save(_ text: String, suggestedName: String) async throws -> Bool {
        calls += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.increment()
        }
        return true
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
