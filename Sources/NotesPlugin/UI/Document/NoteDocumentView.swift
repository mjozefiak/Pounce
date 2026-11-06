import LintelKit
import LintelUI
import SwiftUI

/// The open note (prototype `.ed`). Step 3.2 draws the header: the title, what is known about the note and the
/// switch between its layers; the text under it comes with step 3.3.
struct NoteDocumentView: View {
    let model: NotesWorkspaceModel
    let document: NoteDocumentModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch document.phase {
            case .loading:
                Color.clear
            case .unavailable:
                message(Text("This note is not available right now.", comment: "Document: its source did not answer"))
            case .gone:
                message(Text("This note no longer exists.", comment: "Document: its source no longer has the note"))
            case .loaded:
                if let summary = document.summary {
                    NoteDocumentHeader(model: model, document: document, summary: summary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: document.id) { await model.loadContent(document.id) }
    }

    private func message(_ text: Text) -> some View {
        text
            .font(textSize.font(.callout))
            .foregroundStyle(LintelBrand.secondaryText)
            .padding(24 * textSize.scale)
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
            Text(verbatim: model.presentation.title(summary))
                .font(textSize.font(.title1, weight: .bold))
                .foregroundStyle(LintelBrand.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6 * textSize.scale) {
                ForEach(chips, id: \.self) { chip in
                    Text(verbatim: chip)
                        .font(textSize.font(.footnote))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .padding(.horizontal, 8)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(LintelBrand.hairline))
                }
                Spacer(minLength: 0)
                if document.layers.count > 1 { LayerSwitch(document: document) }
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
