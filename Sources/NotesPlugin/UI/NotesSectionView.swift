import LintelKit
import LintelUI
import SwiftUI

/// The Notes section of the main window (prototype `shell-notes-*`, `.win.nt`): the explorer on the left, the
/// tab bar, path bar and document in the centre, the status bar under both. The shell owns the title bar.
struct NotesSectionView: View {
    let model: NotesWorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ExplorerView(model: model)
                LintelDivider(axis: .vertical)
                VStack(spacing: 0) {
                    NoteTabBar(model: model)
                    NotePathBar(model: model)
                    NoteCenter(model: model)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LintelBrand.windowBackground)
            }
            NotesStatusBar(model: model)
        }
        .background(LintelBrand.windowBackground)
        .task { await model.run() }
    }
}

/// What is under the path bar: the open note's document, or the hint when no tab is open.
struct NoteCenter: View {
    let model: NotesWorkspaceModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        if let document = model.currentDocument {
            NoteDocumentView(model: model, document: document)
                .id(document.id)
        } else {
            VStack(spacing: 6 * textSize.scale) {
                Image(systemName: "note.text")
                    .font(textSize.font(.largeTitle))
                    .foregroundStyle(LintelBrand.secondaryText)
                    .accessibilityHidden(true)
                Text("No note open", comment: "Notes: centre column when no tab is open")
                    .font(textSize.font(.title3, weight: .semibold))
                    .foregroundStyle(LintelBrand.ink)
                Text("Choose a note in the list.", comment: "Notes: hint under the title when no tab is open")
                    .font(textSize.font(.callout))
                    .foregroundStyle(LintelBrand.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The colour of a state dot (prototype `.dot`).
extension NoteStateLevel {
    @MainActor var color: Color {
        switch self {
        case .quiet: LintelBrand.hairline
        case .active: LintelBrand.accent
        case .attention: LintelBrand.statusAttention
        case .error: LintelBrand.statusError
        }
    }
}

extension NoteKind {
    /// The tab's and the document's icon (prototype: people for a meeting, a microphone for a dictation).
    var symbolName: String {
        switch self {
        case .meeting: "person.2"
        case .dictation: "mic"
        default: "note.text"
        }
    }
}
