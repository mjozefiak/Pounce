import LintelKit
import LintelUI
import SwiftUI

/// The open note (prototype `.ed`): the header, then the blocks of the layer on screen. Read-only: notes with
/// their tables and quote chips, the transcript with speakers and times, a dictation's cleaned or original text.
struct NoteDocumentView: View {
    let model: NotesWorkspaceModel
    let document: NoteDocumentModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch document.phase {
            case .loading:
                NoteSkeletonDocument()
            case .unavailable:
                message(Text("This note is not available right now.", comment: "Document: its source did not answer"))
            case .gone:
                message(Text("This note no longer exists.", comment: "Document: its source no longer has the note"))
            case .loaded:
                #if DEBUG
                if let mode = model.qaEditor, !mode.isEmpty {
                    NoteQAEditorDocument(model: model, document: document, readOnly: mode == "readonly")
                } else {
                    loaded
                }
                #else
                loaded
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: document.id) { await model.loadContent(document.id) }
    }

    /// The editor while the note is being edited, else the read-only blocks.
    @ViewBuilder private var loaded: some View {
        if let session = document.session {
            NoteEditingDocument(model: model, document: document, session: session)
                .id(document.layerID)
        } else {
            NoteDocumentBody(model: model, document: document)
        }
    }

    private func message(_ text: Text) -> some View {
        text
            .font(textSize.font(.callout))
            .foregroundStyle(LintelBrand.secondaryText)
            .padding(24 * textSize.scale)
    }
}

/// The scrolling part: the header and one row per block. A quote chip asks the document to show the transcript;
/// the view then scrolls to the block it named.
struct NoteDocumentBody: View {
    let model: NotesWorkspaceModel
    let document: NoteDocumentModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let summary = document.summary {
                        NoteDocumentHeader(model: model, document: document, summary: summary)
                    }
                    if document.blocks.isEmpty {
                        (document.state == .interrupted
                            ? Text("No transcript yet.", comment: "Document: an interrupted meeting has no transcript")
                            : Text("This note has no text yet.", comment: "Document: the shown layer has no text"))
                            .font(textSize.font(.callout))
                            .foregroundStyle(LintelBrand.secondaryText)
                            .padding(.leading, 5.4 * 12.5 * textSize.scale)
                            .padding(.top, 8 * textSize.scale)
                    }
                    ForEach(document.blocks) { block in
                        NoteBlockRow(document: document, block: block, previous: previous(of: block))
                            .id(block.index)
                    }
                }
                .padding(.bottom, 24 * textSize.scale)
            }
            .onChange(of: document.scrollRequest) { _, request in
                guard let request else { return }
                proxy.scrollTo(request.blockIndex, anchor: .center)
            }
        }
    }

    private func previous(of block: NoteBlock) -> NoteBlock? {
        block.index > 0 && block.index - 1 < document.blocks.count ? document.blocks[block.index - 1] : nil
    }
}

/// Title, meta chips and the layer switch (prototype `.dh`).
struct NoteDocumentHeader: View {
    let model: NotesWorkspaceModel
    let document: NoteDocumentModel
    let summary: NoteSummary
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * textSize.scale) {
            if document.isManual {
                NoteTitleField(model: model, document: document, summary: summary)
            } else {
                Text(verbatim: model.presentation.title(summary))
                    .font(textSize.font(.title1, weight: .bold))
                    .foregroundStyle(LintelBrand.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            // The prototype's `.dm{display:flex;flex-wrap:wrap}`: the layer switch drops to its own line when the
            // chips and the switch do not fit (narrow window, large text, Polish).
            NoteWrapLayout(spacing: 6 * textSize.scale, lineSpacing: 6 * textSize.scale) {
                ForEach(chips, id: \.self) { chip in
                    Text(verbatim: chip)
                        .font(textSize.font(.footnote))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(LintelBrand.hairline))
                }
                if document.layers.count > 1 {
                    LayerSwitch(document: document).layoutValue(key: NoteWrapTrailingKey.self, value: true)
                }
            }
        }
        .padding(.top, 20 * textSize.scale)
        .padding(.bottom, 8 * textSize.scale)
        .padding(.leading, 5.4 * 12.5 * textSize.scale)
        .padding(.trailing, 24 * textSize.scale)
    }

    private var chips: [String] {
        var result = [model.presentation.dateTime(summary.startedAt)]
        if let ms = summary.durationMs, ms > 0 {
            result.append(model.presentation.duration(milliseconds: ms, kind: summary.kind))
        }
        if let app = summary.sourceApp, !app.isEmpty { result.append(app) }
        let names = document.speakers.map(\.name).filter { !$0.isEmpty }
        if !names.isEmpty { result.append(names.joined(separator: " · ")) }
        return result
    }
}

/// The segmented switch between layers (prototype `.vs`): Notes and Transcript, Cleaned and Original.
struct LayerSwitch: View {
    let document: NoteDocumentModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(spacing: 0) {
            ForEach(document.layers) { layer in
                let isOn = layer.id == document.layerID
                Button {
                    document.selectLayer(layer.id)
                } label: {
                    Text(verbatim: NoteDocumentModel.title(ofLayer: layer.id))
                        .font(textSize.font(.callout, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? LintelBrand.ink : LintelBrand.secondaryText)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 12 * textSize.scale)
                        .padding(.vertical, 2 * textSize.scale)
                        .background(isOn ? LintelBrand.card : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(LintelBrand.fill, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Show", comment: "Accessibility label of the switch between a note's layers"))
    }
}

struct NoteWrapTrailingKey: LayoutValueKey {
    static let defaultValue = false
}

/// Lays its children out in rows, left to right, starting a new row when one does not fit (CSS `flex-wrap`).
struct NoteWrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(in: proposal.width ?? .infinity, subviews: subviews)
        let width =
            rows.map { $0.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max($0.count - 1, 0)) }.max() ?? 0
        let height =
            rows.reduce(CGFloat(0)) { $0 + (($1.map(\.size.height).max()) ?? 0) } + lineSpacing
            * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(in: bounds.width, subviews: subviews) {
            var x = bounds.minX
            let height = row.map(\.size.height).max() ?? 0
            for item in row {
                // The prototype's `.sp` spacer: a trailing item sits at the right end of its row.
                let left = subviews[item.index][NoteWrapTrailingKey.self] ? max(x, bounds.maxX - item.size.width) : x
                subviews[item.index].place(
                    at: CGPoint(x: left, y: y + (height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + lineSpacing
        }
    }

    private struct Item {
        var index: Int
        var size: CGSize
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> [[Item]] {
        var rows: [[Item]] = [[]]
        var used: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].isEmpty ? size.width : used + spacing + size.width
            if needed > width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                used = size.width
            } else {
                used = needed
            }
            rows[rows.count - 1].append(Item(index: index, size: size))
        }
        return rows
    }
}

/// The title of a manual note (`title_override`): a line you type over, in the header's face. It is written when
/// you press Return or leave the field, never on every key. Empty means "Untitled note".
struct NoteTitleField: View {
    let model: NotesWorkspaceModel
    let document: NoteDocumentModel
    let summary: NoteSummary
    @State private var draft: String
    @FocusState private var focused: Bool
    @Environment(\.lintelTextSize) private var textSize

    init(model: NotesWorkspaceModel, document: NoteDocumentModel, summary: NoteSummary) {
        self.model = model
        self.document = document
        self.summary = summary
        _draft = State(initialValue: summary.title ?? "")
    }

    var body: some View {
        TextField(
            text: $draft, prompt: Text("Untitled note", comment: "Notes: placeholder of a note's title field")
        ) {
            Text("Title", comment: "Accessibility label of a note's title field")
        }
        .textFieldStyle(.plain)
        .font(textSize.font(.title1, weight: .bold))
        .foregroundStyle(LintelBrand.ink)
        .focused($focused)
        .onSubmit(commit)
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        .onChange(of: summary.title) { _, title in if !focused { draft = title ?? "" } }
        .onDisappear(perform: commit)
        .disabled(!model.environment.canEditNotes)
        .accessibilityAddTraits(.isHeader)
    }

    private func commit() {
        let text = draft
        Task { await model.setTitle(document.id, to: text) }
    }
}
