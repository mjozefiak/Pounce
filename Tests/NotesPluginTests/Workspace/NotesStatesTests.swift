import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}()

/// A workspace over scripted sources, with the ports the states need.
@MainActor
private struct StatesRig {
    let meetings: ScriptedNoteSource
    let dictation: ScriptedNoteSource
    let store: FakeOverlayStore
    let box: SourceBox
    let model: NotesWorkspaceModel
    let saver = ScriptedSaver()
    let modelsOpened = Box()

    final class Box { var count = 0 }

    static let key = Fixtures.key("meetings", "m1")

    init(state: NoteState = .ready, items: Int = 1, recordingPlugins: Bool = true) {
        let now = Fixtures.epoch
        let summaries = (0..<items).map { index in
            NoteSummary(
                id: index == 0 ? Self.key : Fixtures.key("meetings", "m\(index + 1)"), kind: .meeting,
                title: index == 0 ? "Budget review" : "Planning \(index)",
                startedAt: now.addingTimeInterval(-Double(3600 + index * 60)), state: index == 0 ? state : .ready)
        }
        meetings = ScriptedNoteSource("meetings", items: summaries)
        dictation = ScriptedNoteSource("dictation", items: [])
        meetings.contents[Self.key] = NoteContent(
            summary: summaries.first ?? NoteSummary(id: Self.key, kind: .meeting, startedAt: now),
            layers: [NoteLayer(id: "transcript", author: .stt, markdown: "Agreed.", version: "1")], speakers: [],
            details: [])
        store = FakeOverlayStore()
        box = SourceBox(recordingPlugins ? [meetings, dictation] : [])
        let opened = modelsOpened
        model = NotesWorkspaceModel(
            environment: NotesWorkspaceModel.Environment(
                library: NoteLibrary(box: box, store: store), pasteboard: RecordingPasteboard(), saver: saver,
                openModels: { opened.count += 1 }, now: { now }, calendar: utc, locale: Locale(identifier: "en_US"),
                pageSize: 2))
    }

    func openFirst() async {
        await model.refresh()
        let id = NoteItemID.live(Self.key)
        model.open(id)
        await model.loadContent(id)
    }
}

@MainActor
@Suite("Notes states: whole section")
struct NotesScreenTests {
    @Test("before the first read the section is loading, with a status line and no count")
    func loading() {
        let rig = StatesRig()
        #expect(rig.model.screen == .loading)
        #expect(rig.model.statusLine?.kind == .busy(progress: nil))
        #expect(rig.model.statusLine?.text == "Opening notes…")
        #expect(rig.model.statusRight.isEmpty)
        #expect(!rig.model.showsEncryptionNote)
    }

    @Test("no notes and a recording plugin on is the empty library, ready")
    func empty() async {
        let rig = StatesRig(items: 0)
        await rig.model.refresh()
        #expect(rig.model.screen == .empty(recordingOff: false))
        #expect(rig.model.statusLine == .init(kind: .ok, text: "Ready"))
        #expect(rig.model.statusRight == "0 notes")
    }

    @Test("no recording plugin on is its own state, notes stay available")
    func recordingOff() async {
        let rig = StatesRig(items: 0, recordingPlugins: false)
        await rig.model.refresh()
        #expect(rig.model.screen == .empty(recordingOff: true))
        #expect(rig.model.recordingOff)
        #expect(rig.model.statusLine == .init(kind: .muted, text: "Recording off"))
        #expect(rig.model.showsEncryptionNote)
        // Switching a recording plugin on leaves the state.
        rig.box.sources = [rig.meetings]
        await rig.model.environment.library.refreshSources()
        await rig.model.refresh()
        #expect(rig.model.screen == .empty(recordingOff: false))
    }

    @Test("a store that cannot be read: locked when nothing is listed, a strip when the sources are")
    func locked() async {
        let rig = StatesRig(items: 0)
        rig.store.failReads = true
        await rig.model.refresh()
        #expect(rig.model.screen == .locked)
        #expect(rig.model.statusLine == .init(kind: .error, text: "Key unavailable"))
        #expect(rig.model.statusRight.isEmpty)
        #expect(rig.model.strips.isEmpty)

        let listed = StatesRig()
        listed.store.failReads = true
        await listed.model.refresh()
        #expect(listed.model.screen == .list)
        #expect(listed.model.rows.count == 1)
        let strip = listed.model.strips.first
        #expect(strip?.id == "locked")
        #expect(strip?.tone == .error)
        #expect(strip?.text == "Lintel can’t read the key to your notes. Nothing was deleted.")
        #expect(strip?.actions.map(\.title) == ["Try again"])
        #expect(listed.model.statusLine?.text == "Key unavailable")

        // Try again reads again; once the key is back the strip is gone.
        listed.store.failReads = false
        await listed.model.perform("locked.retry")
        #expect(listed.model.strips.isEmpty)
        #expect(listed.model.statusLine == nil)
    }

    @Test("a search with no answer says what was asked, and the list comes back with an empty field")
    func noResults() async {
        let rig = StatesRig()
        await rig.model.refresh()
        rig.model.searchText = "invoice 2019"
        await rig.model.runSearch()
        #expect(rig.model.screen == .noResults("invoice 2019"))
        #expect(rig.model.rows.isEmpty)
        await rig.model.clearSearch()
        #expect(rig.model.screen == .list)
        #expect(rig.model.rows.count == 1)
    }

    @Test("a source that did not answer is not shown as an empty library")
    func slowSource() async {
        let rig = StatesRig()
        rig.meetings.behavior = .throwsError
        await rig.model.refresh()
        #expect(rig.model.screen == .list)
    }
}

@MainActor
@Suite("Notes states: strips and status of the open note")
struct NoteStripTests {
    @Test("an interrupted meeting says so and offers what its source offers")
    func interrupted() async {
        let rig = StatesRig(state: .interrupted)
        let performed = Flag()
        rig.meetings.setActions([
            NoteSourceAction(
                id: "meetings.finish", title: LocalizedStringResource("Finish"), symbolName: "checkmark",
                perform: { performed.set() })
        ])
        await rig.openFirst()
        let strip = rig.model.strips.first
        #expect(strip?.id == "interrupted")
        #expect(strip?.tone == .attention)
        #expect(strip?.text == "This meeting was interrupted. Lintel can transcribe the part it recorded.")
        #expect(strip?.actions.map(\.id) == ["doc.meetings.finish"])
        await rig.model.perform("doc.meetings.finish")
        #expect(performed.value)
        #expect(rig.model.currentDocument?.actionFailed == false)
    }

    @Test("an action that throws leaves a strip that can be dismissed, and changes nothing else")
    func actionFails() async throws {
        let rig = StatesRig(state: .interrupted)
        rig.meetings.setActions([
            NoteSourceAction(
                id: "meetings.finish", title: LocalizedStringResource("Finish"), symbolName: "checkmark",
                perform: { throw ScriptedError() })
        ])
        await rig.openFirst()
        await rig.model.perform("doc.meetings.finish")
        let failed = try #require(rig.model.strips.first { $0.id == "actionFailed" })
        #expect(failed.tone == .error)
        #expect(failed.isDismissible)
        rig.model.dismissStrip("actionFailed")
        #expect(rig.model.strips.contains { $0.id == "actionFailed" } == false)
    }

    @Test("a missing notes model: the strip opens Models and the status line says it is not installed")
    func needsModel() async {
        let rig = StatesRig(state: .needsModel)
        await rig.openFirst()
        let strip = rig.model.strips.first
        #expect(strip?.id == "needsModel")
        #expect(strip?.text == "Notes need a model. It downloads once and runs on this Mac.")
        #expect(strip?.actions.map(\.title) == ["Open Models"])
        #expect(rig.model.statusLine == .init(kind: .attention, text: "Notes model not installed"))
        await rig.model.perform("models.open")
        #expect(rig.modelsOpened.count == 1)
    }

    @Test("notes being written: read-only strip with the part, a status line with progress")
    func writing() async {
        let rig = StatesRig(state: .writing(done: 2, of: 5))
        await rig.openFirst()
        let strip = rig.model.strips.first
        #expect(strip?.id == "writing")
        #expect(strip?.tone == .accent)
        #expect(strip?.text == "Agent is writing notes · 2 of 5 · read-only until it finishes")
        #expect(rig.model.statusLine == .init(kind: .busy(progress: 0.4), text: "Writing notes 2/5"))
        #expect(rig.model.statusSummary == "1 notes · 1 writing")
    }

    @Test("a finished note has no strip and no status line")
    func ready() async {
        let rig = StatesRig()
        await rig.openFirst()
        #expect(rig.model.strips.isEmpty)
        #expect(rig.model.statusLine == nil)
    }

    @Test("a failed save: Try again writes to the same place, Choose another place asks, close dismisses")
    func saveError() async throws {
        let rig = StatesRig()
        await rig.openFirst()
        rig.saver.answer = .fails
        await rig.model.saveMarkdown()
        let strip = try #require(rig.model.strips.first)
        #expect(strip.id == "save")
        #expect(strip.tone == .error)
        #expect(strip.isDismissible)
        #expect(strip.actions.map(\.id) == ["save.retry", "save.other"])
        #expect(strip.actions.map(\.title) == ["Try again", "Choose another place…"])

        await rig.model.perform("save.retry")
        #expect(rig.saver.retries == 1)
        #expect(rig.model.feedback == .saveFailed)
        rig.saver.answer = .saved
        await rig.model.perform("save.other")
        #expect(rig.saver.retries == 1)
        #expect(rig.saver.saved.count == 3)
        #expect(rig.model.strips.isEmpty)

        rig.saver.answer = .fails
        await rig.model.saveMarkdown()
        rig.model.dismissStrip("save")
        #expect(rig.model.strips.isEmpty)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
