import Foundation
import LintelKit
import Synchronization
import Testing

@testable import NotesPlugin

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}()

/// What the fake "create a note" port was asked to write, in order.
private final class Created: Sendable {
    private let texts = Mutex<[String]>([])
    var all: [String] { texts.withLock { $0 } }
    func add(_ text: String) { texts.withLock { $0.append(text) } }
}

@MainActor
private struct MakeRig {
    let model: NotesWorkspaceModel
    let dictation: ScriptedNoteSource
    let created = Created()
    static let withCleaned = Fixtures.key("dictation", "s/1")
    static let rawOnly = Fixtures.key("dictation", "s/2")

    init(canWrite: Bool = true, fails: Bool = false, gate: Gate? = nil) {
        let meetings = ScriptedNoteSource(
            "meetings", items: [Fixtures.summary("meetings", "a", secondsAgo: 10, title: "Sync")])
        dictation = ScriptedNoteSource(
            "dictation",
            items: [
                Fixtures.summary("dictation", "s/1", secondsAgo: 20, title: "Buy milk", kind: .dictation),
                Fixtures.summary("dictation", "s/2", secondsAgo: 30, title: "ums", kind: .dictation),
            ])
        dictation.contents[Self.withCleaned] = NoteContent(
            summary: dictation.items[0],
            layers: [
                NoteLayer(id: "cleaned", author: .agent, markdown: "Buy milk.\u{202E}", version: "1"),
                NoteLayer(id: "original", author: .stt, markdown: "um buy milk", version: "1"),
            ], speakers: [], details: [])
        dictation.contents[Self.rawOnly] = NoteContent(
            summary: dictation.items[1],
            layers: [NoteLayer(id: "original", author: .stt, markdown: "just the raw words", version: "1")],
            speakers: [], details: [])
        var environment = NotesWorkspaceModel.Environment(
            library: NoteLibrary(box: SourceBox([meetings, dictation])), pasteboard: RecordingPasteboard(),
            saver: ScriptedSaver(), now: { Fixtures.epoch }, calendar: utc, locale: Locale(identifier: "en_US"))
        environment.canCreateNotes = canWrite
        environment.canEditNotes = canWrite
        let created = created
        environment.createNote = { text in
            await gate?.pass()
            created.add(text)
            return fails ? nil : Fixtures.key("notes", "made-\(created.all.count)")
        }
        model = NotesWorkspaceModel(environment: environment)
    }
}

@MainActor
@Suite("Make note on a dictation")
struct NotesMakeNoteTests {
    @Test("from the Dictations list: the cleaned text becomes a new note that opens in a tab, on the Notes list")
    func makesFromTheList() async throws {
        let rig = MakeRig()
        await rig.model.setCollection(.dictations)
        let id = NoteItemID.live(MakeRig.withCleaned)
        #expect(rig.model.canMakeNote(id))
        await rig.model.makeNote(from: id)
        // Only the cleaned layer, without the bidi control; the raw transcript stays in the dictation.
        #expect(rig.created.all == ["Buy milk."])
        #expect(rig.model.collection == .notes)
        #expect(rig.model.currentID == .live(Fixtures.key("notes", "made-1")))
        #expect(rig.model.documents[rig.model.currentID ?? id]?.wantsEditing == true)
        #expect(rig.model.tabs.tabs.count == 1)
        #expect(rig.model.feedback == .noteMade)
        // The dictation itself got no tab and no write: only its content was read.
        #expect(rig.dictation.deleteCalls == 0)
    }

    @Test("a dictation without a cleaned text uses its transcript")
    func fallsBackToTheTranscript() async {
        let rig = MakeRig()
        await rig.model.setCollection(.dictations)
        await rig.model.makeNote(from: .live(MakeRig.rawOnly))
        #expect(rig.created.all == ["just the raw words"])
    }

    @Test("from the opened dictation, its loaded text is used")
    func fromTheOpenedDictation() async {
        let rig = MakeRig()
        await rig.model.setCollection(.dictations)
        let id = NoteItemID.live(MakeRig.withCleaned)
        rig.model.open(id)
        await rig.model.loadContent(id)
        await rig.model.makeNote(from: id)
        #expect(rig.created.all == ["Buy milk."])
        #expect(rig.model.tabs.tabs.count == 2)
    }

    @Test("a second tap after the first finished makes a second, independent note")
    func secondTapMakesASecondNote() async {
        let rig = MakeRig()
        await rig.model.setCollection(.dictations)
        let id = NoteItemID.live(MakeRig.withCleaned)
        await rig.model.makeNote(from: id)
        await rig.model.setCollection(.dictations)
        await rig.model.makeNote(from: id)
        #expect(rig.created.all == ["Buy milk.", "Buy milk."])
        #expect(rig.model.tabs.tabs.count == 2)
    }

    @Test("while one is being made the action is off, so one tap makes one note")
    func offWhileInFlight() async {
        let gate = Gate()
        let rig = MakeRig(gate: gate)
        await rig.model.setCollection(.dictations)
        let id = NoteItemID.live(MakeRig.withCleaned)
        gate.hold(next: 1)
        let first = Task { await rig.model.makeNote(from: id) }
        await gate.held.wait()
        #expect(rig.model.isMakingNote)
        #expect(!rig.model.canMakeNote(id))
        await rig.model.makeNote(from: id)
        gate.release()
        await first.value
        #expect(rig.created.all == ["Buy milk."])
        #expect(!rig.model.isMakingNote)
    }

    @Test("off when notes cannot be written (read-only or no store), and for anything that is not a dictation")
    func disabled() async {
        let off = MakeRig(canWrite: false)
        await off.model.setCollection(.dictations)
        let id = NoteItemID.live(MakeRig.withCleaned)
        #expect(!off.model.canMakeNote(id))
        await off.model.makeNote(from: id)
        #expect(off.created.all.isEmpty)
        #expect(off.model.tabs.tabs.isEmpty)

        let on = MakeRig()
        #expect(!on.model.canMakeNote(.live(Fixtures.key("meetings", "a"))))
        #expect(!on.model.canMakeNote(.live(Fixtures.key("notes", "x"))))
        #expect(!on.model.canMakeNote(.detached(MakeRig.withCleaned, startedAtMs: 1)))
    }

    @Test("a note that cannot be written says so in a strip, changes nothing and keeps the Dictations list")
    func failure() async {
        let rig = MakeRig(fails: true)
        await rig.model.setCollection(.dictations)
        await rig.model.makeNote(from: .live(MakeRig.withCleaned))
        #expect(rig.model.feedback == .makeNoteFailed)
        #expect(Feedback.isStrip(.makeNoteFailed))
        #expect(rig.model.strips.contains { $0.id == "feedback" && $0.isDismissible })
        #expect(rig.model.collection == .dictations)
        #expect(rig.model.tabs.tabs.isEmpty)
        #expect(!rig.model.isMakingNote)
        // The user can try again: the dictation still holds the text.
        #expect(rig.model.canMakeNote(.live(MakeRig.withCleaned)))
    }

    @Test("a dictation whose source does not answer makes nothing")
    func sourceDown() async {
        let rig = MakeRig()
        await rig.model.setCollection(.dictations)
        rig.dictation.contentBehavior = .throwsError
        await rig.model.makeNote(from: .live(MakeRig.withCleaned))
        #expect(rig.created.all.isEmpty)
        #expect(rig.model.feedback == .makeNoteFailed)
    }
}

private enum Feedback {
    static func isStrip(_ feedback: NotesWorkspaceModel.Feedback) -> Bool { feedback.isStrip }
}

@MainActor
@Suite("Make note writes an independent manual note", .timeLimit(.minutes(1)))
struct NotesMakeNoteStoreTests {
    @Test func theStoreHoldsACopyWithNoLinkAndTheDictationIsUntouched() async throws {
        let r = try ReconRig()
        let dictation = ScriptedNoteSource(
            "dictation",
            items: [Fixtures.summary("dictation", "s/1", secondsAgo: 5, title: "Buy milk", kind: .dictation)])
        let key = Fixtures.key("dictation", "s/1")
        dictation.contents[key] = NoteContent(
            summary: dictation.items[0],
            layers: [NoteLayer(id: "cleaned", author: .agent, markdown: "Buy milk.", version: "1")], speakers: [],
            details: [])
        r.box.sources = [dictation]
        var environment = NotesWorkspaceModel.Environment(library: r.library, pasteboard: RecordingPasteboard())
        environment.registry = r.registry
        let store = r.store
        environment.overlayHeads = { item in (try? NoteOverlayContent.heads(for: item, in: store)) ?? [] }
        environment.installWriting(
            store: { store }, registry: r.registry, settings: r.rig.harness.settings, clock: r.rig.clock)
        let model = NotesWorkspaceModel(environment: environment)
        await model.setCollection(.dictations)
        await model.makeNote(from: .live(key))

        let made = try #require(model.currentID)
        #expect(made.key.pluginID == NotesStore.manualPluginID)
        let document = try #require(try store.liveDocument(key: made.key, layer: NotesStore.manualLayer))
        let head = try #require(try store.headRevision(of: document.id))
        #expect(head.body == "Buy milk.")
        #expect(head.author == "human")
        // No back-link: nothing in Notes refers to the dictation, which has no overlay, revision or comment.
        #expect(try store.liveDocuments(key: key).isEmpty)
        #expect(try store.revisions(of: document.id).count == 1)
        #expect(dictation.deleteCalls == 0)
        #expect(model.currentDocument?.phase == .loaded)
        #expect(model.currentDocument?.selectedLayer?.markdown == "Buy milk.")
    }
}
