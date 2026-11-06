import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}()

/// A workspace over two scripted meetings and one dictation, with commands the palette can run.
@MainActor
private struct PaletteRig {
    let model: NotesWorkspaceModel
    let ran = Ran()

    final class Ran { var names: [String] = [] }

    static let orchard = Fixtures.key("meetings", "orchard")
    static let review = Fixtures.key("meetings", "review")
    static let dictation = Fixtures.key("dictation", "store/7")

    init() async {
        let now = Fixtures.epoch
        let source = ScriptedNoteSource(
            "meetings",
            items: [
                NoteSummary(
                    id: Self.orchard, kind: .meeting, title: "Orchard weekly sync",
                    startedAt: now.addingTimeInterval(-3600)),
                NoteSummary(
                    id: Self.review, kind: .meeting, title: "Design review",
                    startedAt: now.addingTimeInterval(-90_000)),
            ])
        let dictation = ScriptedNoteSource(
            "dictation",
            items: [
                NoteSummary(
                    id: Self.dictation, kind: .dictation, title: "Łódź plan", startedAt: now.addingTimeInterval(-7200))
            ])
        let (stream, _) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        var environment = NotesWorkspaceModel.Environment(
            library: NoteLibrary(box: SourceBox([source, dictation])), pasteboard: RecordingPasteboard(),
            saver: ScriptedSaver(), sourceSetChanges: { stream }, now: { now }, calendar: utc,
            locale: Locale(identifier: "en_US"))
        let ran = ran
        environment.availableCommands = {
            [
                CommandInfo(
                    title: LocalizedStringResource("Record a meeting", comment: "test"),
                    shortcut: KeyShortcut(key: "m", modifiers: [.control, .option]), run: { ran.names.append("record") }
                ),
                CommandInfo(
                    title: LocalizedStringResource("Open Settings", comment: "test"),
                    shortcut: KeyShortcut(key: ",", modifiers: [.command]), run: { ran.names.append("settings") }),
                CommandInfo(
                    title: LocalizedStringResource("Disabled one", comment: "test"), isEnabled: { false },
                    run: { ran.names.append("disabled") }),
            ]
        }
        model = NotesWorkspaceModel(environment: environment)
        await model.refresh()
    }
}

@MainActor
@Suite("Notes palette (⌘P) and Hide content (⌘⇧H)")
struct NotesPaletteTests {
    @Test("an empty query lists the newest notes, then every enabled command with its shortcut")
    func emptyQuery() async {
        let rig = await PaletteRig()
        rig.model.showPalette()
        let items = rig.model.paletteItems
        #expect(
            items.map(\.title) == [
                "Orchard weekly sync", "Łódź plan", "Design review", "Record a meeting", "Open Settings",
                "Hide content",
            ])
        #expect(Array(items.map(\.detail).suffix(3)) == ["⌃⌥M", "⌘,", "⌘⇧H"], "\(items.map(\.detail))")
        #expect(items[0].detail.hasSuffix("· meeting"))
        #expect(items[1].detail.hasSuffix("· dictation"))
    }

    @Test("a query keeps what holds every word, ignoring case and accents, with prefix matches first")
    func filtering() async {
        let rig = await PaletteRig()
        rig.model.showPalette()
        rig.model.setPaletteQuery("lodz")
        #expect(rig.model.paletteItems.map(\.title) == ["Łódź plan"])
        rig.model.setPaletteQuery("RE")
        // "Record a meeting" and "Design review" both hold "re"; the one that starts with it comes first within its kind.
        #expect(rig.model.paletteItems.map(\.title) == ["Design review", "Record a meeting"])
        rig.model.setPaletteQuery("nothing like this")
        #expect(rig.model.paletteItems.isEmpty)
    }

    @Test("Return opens the selected note in its tab and closes the palette")
    func openingANote() async {
        let rig = await PaletteRig()
        rig.model.showPalette()
        rig.model.movePaletteSelection(by: 1)
        rig.model.runPalette()
        #expect(rig.model.palette == nil)
        #expect(rig.model.currentID == .live(PaletteRig.dictation))
    }

    @Test("a command runs once; a disabled command is not offered")
    func runningACommand() async {
        let rig = await PaletteRig()
        rig.model.showPalette()
        #expect(!rig.model.paletteItems.contains { $0.title == "Disabled one" })
        rig.model.setPaletteQuery("settings")
        rig.model.runPalette()
        #expect(rig.ran.names == ["settings"])
        #expect(rig.model.palette == nil)
    }

    @Test("the selection wraps around at both ends")
    func selectionWraps() async {
        let rig = await PaletteRig()
        rig.model.showPalette()
        let count = rig.model.paletteItems.count
        rig.model.movePaletteSelection(by: -1)
        #expect(rig.model.palette?.selection == count - 1)
        rig.model.movePaletteSelection(by: 1)
        #expect(rig.model.palette?.selection == 0)
    }

    @Test("Hide content masks titles, adds the strip and is never persisted; the palette does not open while hidden")
    func hidingContent() async {
        let rig = await PaletteRig()
        rig.model.open(.live(PaletteRig.orchard))
        #expect(rig.model.shown("Orchard weekly sync") == "Orchard weekly sync")
        rig.model.toggleHideContent()
        #expect(rig.model.hidesContent)
        #expect(rig.model.shown("Orchard weekly sync") == "••••••")
        #expect(rig.model.shownPath(["Today", "Orchard weekly sync"]) == ["Today", "••••••"])
        #expect(rig.model.strips.first?.id == "hidden")
        #expect(rig.model.strips.first?.actions.first?.id == "hidden.show")
        rig.model.showPalette()
        #expect(rig.model.palette == nil)
        // The strip's "Show content" brings everything back.
        await rig.model.perform("hidden.show")
        #expect(!rig.model.hidesContent)
        #expect(!rig.model.strips.contains { $0.id == "hidden" })
    }

    @Test("Hide content toggles through the palette and closes it")
    func hideThroughThePalette() async {
        let rig = await PaletteRig()
        rig.model.showPalette()
        rig.model.setPaletteQuery("hide")
        rig.model.runPalette()
        #expect(rig.model.hidesContent)
        #expect(rig.model.palette == nil)
        // The command now offers the way back.
        #expect(rig.model.paletteCommands.last?.title == "Show content")
    }

    @Test("the inspector gives way first: it needs the explorer, itself and a centre that grows with the text size")
    func inspectorFit() {
        #expect(NotesWorkspaceModel.inspectorFits(sectionWidth: 1100, textScale: 1))
        #expect(!NotesWorkspaceModel.inspectorFits(sectionWidth: 900, textScale: 1))
        // The same width that fits at Medium does not at Extra Large (scale 1.3).
        #expect(NotesWorkspaceModel.inspectorFits(sectionWidth: 1000, textScale: 1))
        #expect(!NotesWorkspaceModel.inspectorFits(sectionWidth: 1000, textScale: 1.3))
        #expect(NotesWorkspaceModel.inspectorFits(sectionWidth: 1200, textScale: 1.3))
    }

    @Test("a narrow section hides the inspector and a wide one brings it back, unless the user chose")
    func inspectorFollowsTheWidth() async {
        let rig = await PaletteRig()
        #expect(rig.model.inspectorVisible)
        rig.model.updateInspectorFit(sectionWidth: 880, textScale: 1)
        #expect(!rig.model.inspectorVisible)
        rig.model.updateInspectorFit(sectionWidth: 1400, textScale: 1)
        #expect(rig.model.inspectorVisible)
        // Hidden by hand, it stays hidden when the room comes back.
        rig.model.setInspectorVisible(false)
        rig.model.updateInspectorFit(sectionWidth: 880, textScale: 1)
        rig.model.updateInspectorFit(sectionWidth: 1400, textScale: 1)
        #expect(!rig.model.inspectorVisible)
    }
}

@Suite("Command palette entries")
struct CommandPaletteEntriesTests {
    @Test("the limits: five notes without a query, eight with one")
    func limits() {
        let notes = (0..<20).map { index in
            (
                id: NoteItemID.live(Fixtures.key("meetings", "n\(index)")),
                candidate: PaletteCandidate(title: "Note \(index)", detail: "")
            )
        }
        #expect(CommandPaletteEntries.build(notes: notes, commands: [], query: "").count == 5)
        #expect(CommandPaletteEntries.build(notes: notes, commands: [], query: "note").count == 8)
    }

    @Test("ids are unique even for a live note and a detached copy of the same key")
    func uniqueIDs() {
        let key = Fixtures.key("meetings", "a")
        let notes = [
            (id: NoteItemID.live(key), candidate: PaletteCandidate(title: "A", detail: "")),
            (id: NoteItemID.detached(key, startedAtMs: 5), candidate: PaletteCandidate(title: "A", detail: "")),
        ]
        let ids = CommandPaletteEntries.build(notes: notes, commands: [], query: "").map(\.id)
        #expect(Set(ids).count == 2)
    }
}
