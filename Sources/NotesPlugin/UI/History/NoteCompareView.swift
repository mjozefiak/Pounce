import LintelKit
import LintelUI
import SwiftUI

/// Compare (prototype `diffDoc`): "Compare", the two versions as chips, then the changed blocks inline, each with
/// the author of the block. The prototype's "Side by side" is a later addition (spec deviation 4).
struct NoteCompareView: View {
    let model: NotesWorkspaceModel
    let document: NoteDocumentModel
    let compare: CompareState
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if compare.result.isEmpty {
                    Text("No differences.", comment: "Compare: the two versions have the same text")
                        .font(textSize.font(.callout))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .padding(.leading, 5.4 * 12.5 * textSize.scale)
                        .padding(.top, 8 * textSize.scale)
                } else {
                    VStack(spacing: 0) {
                        ForEach(compare.result.lines) { line in NoteDiffLineView(line: line) }
                    }
                    .padding(.leading, 5.4 * 12.5 * textSize.scale - 10)
                    .padding(.trailing, 24 * textSize.scale)
                }
            }
            .padding(.bottom, 24 * textSize.scale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                LocalizedStringResource(
                    "compare.title", defaultValue: "Compare",
                    comment: "Accessibility label of the comparison of two versions")))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8 * textSize.scale) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    LocalizedStringResource(
                        "compare.title", defaultValue: "Compare",
                        comment: "Compare: title of the comparison of two versions")
                )
                .font(textSize.font(.title1, weight: .bold))
                .foregroundStyle(LintelBrand.ink)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Button {
                    model.closeCompare()
                } label: {
                    Text("Back to the note", comment: "Compare: returns to the note's text")
                        .font(textSize.font(.footnote, weight: .semibold))
                        .foregroundStyle(LintelBrand.accentText)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            NoteWrapLayout(spacing: 6 * textSize.scale, lineSpacing: 6 * textSize.scale) {
                chip(compare.baseAuthor, compare.baseDate)
                Text(verbatim: "→")
                    .font(textSize.font(.footnote))
                    .foregroundStyle(LintelBrand.secondaryText)
                    .accessibilityHidden(true)
                chip(compare.author, compare.date)
                Text("Inline", comment: "Compare: the changes are shown in the text")
                    .font(textSize.font(.footnote, weight: .semibold))
                    .foregroundStyle(LintelBrand.ink)
                    .padding(.horizontal, 12 * textSize.scale)
                    .padding(.vertical, 2 * textSize.scale)
                    .background(LintelBrand.card, in: RoundedRectangle(cornerRadius: 5))
                    .padding(2)
                    .background(LintelBrand.fill, in: RoundedRectangle(cornerRadius: 7))
                    .layoutValue(key: NoteWrapTrailingKey.self, value: true)
            }
        }
        .padding(.top, 20 * textSize.scale)
        .padding(.bottom, 8 * textSize.scale)
        .padding(.leading, 5.4 * 12.5 * textSize.scale)
        .padding(.trailing, 24 * textSize.scale)
    }

    private func chip(_ author: NoteAuthor, _ date: Date) -> some View {
        Text(verbatim: "\(author.gutterText) \(model.presentation.time(date))")
            .font(textSize.font(.footnote))
            .foregroundStyle(LintelBrand.ink)
            .padding(.horizontal, 8)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(LintelBrand.hairline))
            .accessibilityLabel(Text(verbatim: "\(author.spokenName), \(model.presentation.dateTime(date))"))
    }
}

/// One line of the inline diff (prototype `.dl`): the glyph, the block, the author of the block.
struct NoteDiffLineView: View {
    let line: NoteDiffLine
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: glyph)
                .foregroundStyle(glyphColor)
                .frame(width: 12.5 * textSize.scale, alignment: .leading)
                .accessibilityHidden(true)
            Text(verbatim: line.text)
                .foregroundStyle(LintelBrand.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let author = line.author {
                Text(verbatim: author.gutterText)
                    .font(textSize.font(.footnote))
                    .foregroundStyle(LintelBrand.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .font(textSize.font(.callout))
        .padding(.horizontal, 10)
        .padding(.vertical, 5 * textSize.scale)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    private var glyph: String {
        switch line.kind {
        case .context: " "
        case .removed: "−"
        case .added: "+"
        }
    }

    private var glyphColor: Color {
        switch line.kind {
        case .context: LintelBrand.secondaryText
        case .removed: LintelBrand.statusError
        case .added: LintelBrand.statusOk
        }
    }

    private var background: Color {
        switch line.kind {
        case .context: .clear
        case .removed: LintelBrand.statusError.opacity(0.12)
        case .added: LintelBrand.statusOk.opacity(0.13)
        }
    }

    private var spoken: String {
        switch line.kind {
        case .context: line.text
        case .removed:
            String(
                localized: "Removed: \(line.text)", comment: "Accessibility: a block the newer version no longer has")
        case .added:
            String(localized: "Added: \(line.text)", comment: "Accessibility: a block the newer version has")
        }
    }
}
