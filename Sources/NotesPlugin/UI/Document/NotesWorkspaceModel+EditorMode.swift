import LintelKit

extension NotesWorkspaceModel {
    /// ⌥⌘R: Formatted / Raw. Free in the main menu (⌥⌘M is Minimize All, ⇧⌘M comments).
    static let editorModeShortcut = KeyShortcut(key: "r", modifiers: [.command, .option])

    /// The switch is offered while a note is in the editor (and, in DEBUG, for the QA editor).
    var canSwitchEditorMode: Bool {
        if currentDocument?.isEditing == true { return true }
        #if DEBUG
        if let qa = qaEditor, !qa.isEmpty, currentDocument != nil { return true }
        #endif
        return false
    }

    /// Changes how the editor shows the buffer. Only the mode changes: the text, selection and undo stay, and
    /// nothing is saved or revised by it.
    func setEditorMode(_ mode: NoteEditorMode) {
        guard canSwitchEditorMode else { return }
        editorMode = mode
    }

    func toggleEditorMode() { setEditorMode(editorMode.toggled) }
}
