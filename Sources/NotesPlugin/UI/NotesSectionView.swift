import LintelKit
import LintelUI
import SwiftUI

/// The Notes section of the main window (prototype `shell-notes-*`, `.win.nt`): the explorer on the left, the
/// tab bar, path bar and document in the centre, the status bar under both. The shell owns the title bar.
struct NotesSectionView: View {
    let model: NotesWorkspaceModel

    /// Never shown: the sheet is presented only while a request exists.
    private static let placeholder = DestructiveConfirmation(
        prompt: LocalizedStringResource("Delete this note?", comment: "Notes: title of the delete sheet"),
        detail: LocalizedStringResource("This can’t be undone.", comment: "Notes: delete sheet text"),
        confirmTitle: LocalizedStringResource("Delete", comment: "Notes: delete sheet button"))

    @Environment(\.lintelTextSize) private var textSize

    /// The inspector of the open note, when it is loaded.
    private var inspectorDocument: NoteDocumentModel? {
        guard model.inspectorVisible, let document = model.currentDocument, document.phase == .loaded else {
            return nil
        }
        return document
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ExplorerView(model: model)
                LintelDivider(axis: .vertical)
                VStack(spacing: 0) {
                    NoteTabBar(model: model)
                    NotePathBar(model: model)
                    NoteCenter(model: model)
                        .hiddenContent(model.hidesContent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LintelBrand.windowBackground)
                // Next to the document when there is room; over its right edge when the section is narrow (the
                // path bar's button asked for it), so Comments and History stay reachable at the largest text size.
                .overlay(alignment: .trailing) {
                    if let document = inspectorDocument, !model.inspectorFits {
                        NoteInspector(model: model, document: document)
                            .hiddenContent(model.hidesContent)
                            .shadow(color: LintelBrand.ink.opacity(0.2), radius: 14, x: -4)
                    }
                }
                if let document = inspectorDocument, model.inspectorFits {
                    NoteInspector(model: model, document: document)
                        .hiddenContent(model.hidesContent)
                }
            }
            NotesStatusBar(model: model)
        }
        .background(LintelBrand.windowBackground)
        .overlay {
            if model.palette != nil { NoteCommandPalette(model: model) }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            model.updateInspectorFit(sectionWidth: width, textScale: textSize.scale)
        }
        // The text size changes what the centre column needs, so the same width may now be too narrow.
        .onChange(of: textSize.scale) {
            model.updateInspectorFit(sectionWidth: model.sectionWidth, textScale: textSize.scale)
        }
        .environment(model.preferences)
        .task { await model.run() }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { model.pendingDelete != nil }, set: { if !$0 { model.cancelDelete() } }),
            model.pendingDelete.map(NoteDeleteConfirmation.make) ?? Self.placeholder
        ) {
            // Closing the sheet clears the request, so the task takes it now.
            guard let request = model.pendingDelete else { return }
            Task { await model.confirmDelete(request) }
        }
    }
}

/// What is under the path bar: the open note's document, or what the section has to say when no tab is open.
struct NoteCenter: View {
    let model: NotesWorkspaceModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        if let document = model.currentDocument {
            NoteDocumentView(model: model, document: document)
                .id(document.id)
        } else {
            switch model.screen {
            case .list:
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
            case let screen:
                NoteScreenView(model: model, screen: screen)
            }
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
