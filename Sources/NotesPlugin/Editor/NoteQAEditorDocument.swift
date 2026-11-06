#if DEBUG
import LintelKit
import LintelUI
import SwiftUI

/// DEBUG only (`plugins.notes.qaEditor`): the open note's header and its Markdown in the editor, so QA can look
/// at the editor before saving exists. The buffer lives in this view; nothing is written anywhere.
struct NoteQAEditorDocument: View {
    let model: NotesWorkspaceModel
    let document: NoteDocumentModel
    let readOnly: Bool
    @State private var buffer: String

    init(model: NotesWorkspaceModel, document: NoteDocumentModel, readOnly: Bool) {
        self.model = model
        self.document = document
        self.readOnly = readOnly
        _buffer = State(initialValue: document.markdown ?? "")
    }

    var body: some View {
        NoteEditorSurface(text: $buffer, pasteboard: model.environment.pasteboard, isReadOnly: readOnly) {
            if let summary = document.summary {
                NoteDocumentHeader(model: model, document: document, summary: summary)
            }
        }
    }
}
#endif
