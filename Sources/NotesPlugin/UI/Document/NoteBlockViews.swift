import LintelKit
import LintelUI
import SwiftUI

/// One block of a note (prototype `.blk`): the Markdown drawn as text. The notes are a summary, so a block shows
/// no author bar, no mark and no time: who wrote what is in the History tab, and the times stay in the transcript.
/// The attribution is still stored with every revision (`BlockAttribution`); it is only not drawn here.
struct NoteBlockRow: View {
    let document: NoteDocumentModel
    let block: NoteBlock
    let previous: NoteBlock?
    @Environment(\.lintelTextSize) private var textSize

    private var isTranscript: Bool { document.layerID == NoteDocumentModel.transcriptLayerID }

    var body: some View {
        Group {
            if isTranscript {
                TranscriptLine(document: document, block: block)
            } else {
                NoteBlockBody(document: document, block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        // The text starts where the header's does (prototype: the gutter's width, now left empty).
        .padding(.leading, 5.4 * 12.5 * textSize.scale)
        .padding(.trailing, 28 * textSize.scale)
    }
}

/// Text from a source, drawn as inline Markdown with no link and no image. A trailing `[mm:ss]` that an older
/// note carries is cut off: the notes show no times.
struct NoteInlineText: View {
    let document: NoteDocumentModel
    let text: String
    var font: Font?
    @Environment(\.lintelTextSize) private var textSize
    /// `MeetingNoteLayers.notesLayerID`; NotesPlugin never imports MeetingsPlugin.
    static let meetingNotesLayerID = "notes"

    var body: some View {
        // Only the meeting notes layer ever carried `[mm:ss]`; a time the user typed elsewhere stays.
        let shown = document.layerID == NoteInlineText.meetingNotesLayerID ? NoteQuote.split(text).text : text
        Text(NoteInline.attributed(shown))
            .font(font ?? textSize.font(.callout))
            .foregroundStyle(LintelBrand.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

/// The body of a block of notes or of a dictation.
struct NoteBlockBody: View {
    let document: NoteDocumentModel
    let block: NoteBlock
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(NoteInline.attributed(text))
                .font(textSize.font(level <= 1 ? .title2 : level == 2 ? .title3 : .headline, weight: .bold))
                .foregroundStyle(LintelBrand.ink)
                .padding(.top, 6 * textSize.scale)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            NoteInlineText(document: document, text: text)
        case .list(let lines):
            VStack(alignment: .leading, spacing: 2 * textSize.scale) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    NoteListLine(document: document, line: line)
                }
            }
        case .table(let table):
            NoteTableView(document: document, table: table)
        case .code(let code):
            Text(verbatim: code)
                .font(textSize.font(.footnote).monospaced())
                .foregroundStyle(LintelBrand.ink)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LintelBrand.fill, in: RoundedRectangle(cornerRadius: 6))
        case .quote(let text):
            Text(NoteInline.attributed(text))
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
                .padding(.leading, 8)
                .overlay(alignment: .leading) { LintelBrand.accent.frame(width: 2) }
        }
    }
}

struct NoteListLine: View {
    let document: NoteDocumentModel
    let line: NoteBlock.ListLine
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
                .frame(minWidth: 14 * textSize.scale, alignment: .trailing)
                .accessibilityHidden(true)
            NoteInlineText(document: document, text: line.text)
        }
        .padding(.leading, CGFloat(line.depth) * 18 * textSize.scale)
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(verbatim: taskState))
    }

    /// "Done" or "Not done" for a task, nothing for any other item.
    private var taskState: String {
        guard case .task(let done) = line.marker else { return "" }
        return done
            ? String(localized: "Done", comment: "Accessibility: a finished task in a note")
            : String(localized: "Not done", comment: "Accessibility: an open task in a note")
    }

    @ViewBuilder private var marker: some View {
        switch line.marker {
        case .bullet: Text(verbatim: "•")
        case .number(let number): Text(verbatim: "\(number).")
        case .task(let done): Image(systemName: done ? "checkmark.square" : "square")
        }
    }
}

/// A table (prototype `.bd table`): hairline cell borders, a quiet header row.
struct NoteTableView: View {
    let document: NoteDocumentModel
    let table: NoteBlock.Table
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                    Text(NoteInline.attributed(cell))
                        .font(textSize.font(.footnote, weight: .semibold))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .tableCell()
                }
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        NoteInlineText(document: document, text: cell).tableCell()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { LintelDivider() }
        .overlay(alignment: .leading) { LintelDivider(axis: .vertical) }
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// A table cell: padding and the hairline on its right and bottom edges.
    fileprivate func tableCell() -> some View {
        modifier(TableCellStyle())
    }
}

private struct TableCellStyle: ViewModifier {
    @Environment(\.lintelTextSize) private var textSize

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10 * textSize.scale)
            .padding(.vertical, 7 * textSize.scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .trailing) { LintelDivider(axis: .vertical) }
            .overlay(alignment: .bottom) { LintelDivider() }
    }
}

/// One transcript segment (prototype `.tl`): the speaker, the time it started and the words. A segment a quote
/// chip jumped to is tinted.
struct TranscriptLine: View {
    let document: NoteDocumentModel
    let block: NoteBlock
    @Environment(\.lintelTextSize) private var textSize

    private var isHighlighted: Bool { document.highlightedBlock == block.index }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12 * textSize.scale) {
            if let name = document.speakerName(of: block) {
                Text(verbatim: name)
                    .font(textSize.font(.callout, weight: .bold))
                    .foregroundStyle(LintelBrand.ink)
                    .lineLimit(1)
                    .frame(width: 5.5 * 12.5 * textSize.scale, alignment: .leading)
            }
            if let start = block.startMs {
                Text(verbatim: NoteQuote.clock(milliseconds: start))
                    .font(textSize.font(.footnote).monospaced())
                    .foregroundStyle(LintelBrand.accentText)
                    .padding(.horizontal, 6)
                    .background(LintelBrand.fill, in: RoundedRectangle(cornerRadius: 4))
            }
            Text(NoteInline.attributed(block.source))
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .background(
            isHighlighted ? LintelBrand.windowSelectionTint : Color.clear, in: RoundedRectangle(cornerRadius: 4)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}
