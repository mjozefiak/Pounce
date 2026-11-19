import LintelKit
import LintelUI
import SwiftUI

/// The open note in the editor (prototype `mode: 'edit'`: format bar, the header, then the Markdown). The buffer is the layer's Markdown as the editor rendered it; every edit goes to the note's writer
/// through its `NoteEditingSession`, which writes at most a second later and at every save point (spec "Saving").
struct NoteEditingDocument: View {
    let model: NotesWorkspaceModel
    let document: NoteDocumentModel
    let session: NoteEditingSession
    @State private var buffer: String
    @Environment(NoteViewPreferences.self) private var preferences

    init(model: NotesWorkspaceModel, document: NoteDocumentModel, session: NoteEditingSession) {
        self.model = model
        self.document = document
        self.session = session
        _buffer = State(initialValue: document.selectedLayer?.markdown ?? "")
    }

    var body: some View {
        var surface = NoteEditorSurface(
            text: $buffer, pasteboard: model.environment.pasteboard, isReadOnly: !session.isEditable,
            wrapsLines: preferences.wrapLines, mode: model.editorMode,
            onAddComment: model.canWriteComments(document) && session.canComment
                ? { body, selection, text in await model.addComment(body: body, selection: selection, buffer: text) }
                : nil,
            highlights: preferences.showComments ? document.highlights : [],
            onSelectThread: { document.selectedThreadID = $0 },
            onFocusChange: { focused in
                // Losing focus is a save point.
                if !focused { Task { await session.flush() } }
            },
            onEdit: {
                session.handle($0)
                document.setEditorText($0.text, edit: $0)
            },
            header: {
                if let summary = document.summary {
                    NoteDocumentHeader(model: model, document: document, summary: summary)
                }
            })
        surface.onCommentRefused = { failure in
            model.show(failure == .selectionTooLong ? .commentSelectionTooLong : .commentSelectionInvalid)
        }
        #if DEBUG
        surface.qaSelect = document.qaCommentQuote
        #endif
        return surface
    }
}
