import LintelKit
import LintelUI
import SwiftUI

/// The words of the delete sheets (prototype `dlg-delete-meeting`, `dlg-delete-dictation`). The title is other
/// people's words and is shown verbatim inside the quotes.
enum NoteDeleteConfirmation {
    static func make(_ request: NotesWorkspaceModel.DeleteRequest) -> DestructiveConfirmation {
        let title = request.title
        switch request.subject {
        case .meeting:
            return DestructiveConfirmation(
                prompt: LocalizedStringResource("Delete “\(title)”?", comment: "Notes: title of the delete sheet"),
                detail: request.hasEdits
                    ? LocalizedStringResource(
                        "Its notes and transcript, and your edits to them, are removed from this Mac. This can’t be undone.",
                        comment: "Notes: delete sheet of a meeting with edits")
                    : LocalizedStringResource(
                        "Its notes and transcript are removed from this Mac. This can’t be undone.",
                        comment: "Notes: delete sheet of a meeting"),
                confirmTitle: LocalizedStringResource("Delete Meeting", comment: "Notes: delete sheet button"))
        case .dictation:
            return DestructiveConfirmation(
                prompt: LocalizedStringResource("Delete this dictation?", comment: "Notes: title of the delete sheet"),
                detail: request.hasEdits
                    ? LocalizedStringResource(
                        "The text, and your edits to it, are removed from your history. This can’t be undone.",
                        comment: "Notes: delete sheet of a dictation with edits")
                    : LocalizedStringResource(
                        "The text is removed from your history. This can’t be undone.",
                        comment: "Notes: delete sheet of a dictation"),
                confirmTitle: LocalizedStringResource("Delete Dictation", comment: "Notes: delete sheet button"))
        case .manual:
            return DestructiveConfirmation(
                prompt: LocalizedStringResource("Delete “\(title)”?", comment: "Notes: title of the delete sheet"),
                detail: LocalizedStringResource(
                    "The note is removed from this Mac. This can’t be undone.",
                    comment: "Notes: delete sheet of a note you wrote"),
                confirmTitle: LocalizedStringResource("Delete Note", comment: "Notes: delete sheet button"))
        case .copy:
            return DestructiveConfirmation(
                prompt: LocalizedStringResource("Delete “\(title)”?", comment: "Notes: title of the delete sheet"),
                detail: LocalizedStringResource(
                    "Your edited copy of this note is removed from this Mac. This can’t be undone.",
                    comment: "Notes: delete sheet of the copy of a recording that is gone"),
                confirmTitle: LocalizedStringResource("Delete Copy", comment: "Notes: delete sheet button"))
        }
    }
}
