/// How the editor shows the one Markdown buffer. Both modes edit the same text storage, so switching never changes
/// the text, the selection or the undo history, never counts as an edit, and the saved source is the same.
enum NoteEditorMode: String, CaseIterable, Sendable {
    /// The Markdown source with its markers visible and the styling per block (headings, bold, lists, quotes) and
    /// the author gutter.
    case formatted
    /// Plain monospaced Markdown source: no block styling and no author decoration. Formatting is typed by hand.
    case raw

    var toggled: NoteEditorMode { self == .formatted ? .raw : .formatted }

    /// Whether the text is styled per block (headings, emphasis, list markers, code wells).
    var stylesBlocks: Bool { self == .formatted }

    /// Whether the format bar's formatting buttons and ⌘B / ⌘I act. The Comment button is not a format.
    var offersFormatting: Bool { self == .formatted }

    /// The author bars in the gutter: the user's Details toggle, and never in Raw.
    func showsAuthorBars(preference: Bool) -> Bool { self == .formatted && preference }

    /// `plugins.notes.qaEditorMode` (DEBUG only): `raw` starts in Raw; anything else is the default.
    static func qa(_ value: String?) -> NoteEditorMode { value == "raw" ? .raw : .formatted }
}
