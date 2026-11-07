import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

/// The explorer's prominent "New note" button and the tab bar's plus share the ⌘N menu item's rule and action.
@MainActor
@Suite("Notes: the New note button")
struct NewNoteButtonTests {
    private final class Created: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func bump() { lock.withLock { value += 1 } }
    }

    private nonisolated static let newKey = Fixtures.key("notes", "fresh")

    private func model(canCreate: Bool, created: Created) -> NotesWorkspaceModel {
        let (stream, _) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let source = ScriptedNoteSource("meetings", items: [])
        var environment = NotesWorkspaceModel.Environment(
            library: NoteLibrary(box: SourceBox([source])), pasteboard: RecordingPasteboard(),
            saver: ScriptedSaver(), sourceSetChanges: { stream })
        environment.canCreateNotes = canCreate
        environment.createManualNote = {
            created.bump()
            return Self.newKey
        }
        return NotesWorkspaceModel(environment: environment)
    }

    @Test("the button is on exactly when ⌘N is: off without the store or in read-only mode")
    func enabledLikeTheMenuItem() async {
        let created = Created()
        let off = model(canCreate: false, created: created)
        #expect(!off.newNoteAffordance.isEnabled)
        #expect(off.newNoteAffordance.isEnabled == off.canCreateNote)
        let on = model(canCreate: true, created: created)
        #expect(on.newNoteAffordance.isEnabled)
        #expect(on.newNoteAffordance.isEnabled == on.canCreateNote)
    }

    @Test("the button's action creates one note and opens it; a disabled button creates nothing")
    func runsTheSameAction() async {
        let created = Created()
        let off = model(canCreate: false, created: created)
        await off.newNote()
        #expect(created.count == 0)
        #expect(off.tabs.tabs.isEmpty)

        let on = model(canCreate: true, created: created)
        await on.newNote()
        #expect(created.count == 1)
        #expect(on.currentID == .live(Self.newKey))
    }

    @Test("the hint on the button is the shortcut of the menu item")
    func hintIsTheShortcut() {
        #expect(NewNoteAffordance.shortcutHint == "⌘N")
    }
}
