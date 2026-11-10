import Foundation

/// Where the quotes of the open threads are in the text, worked out once per change instead of once per read (the
/// highlights, the "Text changed" labels and the Revise count read it on every redraw). Pure value.
struct CommentResolutions: Equatable, Sendable {
    /// Open threads only.
    var entries: [Int64: AnchorResolution] = [:]
    /// How many open threads a Revise run would take on this text (the others are skipped, see `ReviseUnitPlanner`).
    var revisable = 0

    /// Moves the cached ranges after an edit without searching again: a range behind the edit shifts by the change
    /// in length. A range the edit touched keeps its old place until the next resolve, which comes a moment later.
    mutating func apply(_ edit: NoteEditorEdit) {
        let oldEnd = edit.range.upperBound - edit.changeInLength
        for (id, resolution) in entries {
            guard case .found(let range) = resolution, range.location >= oldEnd else { continue }
            entries[id] = .found(NSRange(location: range.location + edit.changeInLength, length: range.length))
        }
    }
}
