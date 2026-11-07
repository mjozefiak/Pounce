import LintelKit
import LintelUI
import SwiftUI

/// One block with its author bar (prototype `.blk`): the gutter names who wrote it (AI, You, STT) next to a bar,
/// and the body draws the Markdown. Every block has its own author (`BlockAttribution`, spec step 4.3): a block
/// the user edited is "You" even in a note the model wrote. A block that is no longer the seeded one says so, and
/// loses its quote chips. VoiceOver hears the author, and the mark, at every block, also when the bars are off.
struct NoteBlockRow: View {
    let document: NoteDocumentModel
    let block: NoteBlock
    let previous: NoteBlock?
    @Environment(\.lintelTextSize) private var textSize
    @Environment(NoteViewPreferences.self) private var preferences

    private var info: BlockAttributionInfo { document.info(forBlockAt: block.index) }
    private var isTranscript: Bool { document.layerID == NoteDocumentModel.transcriptLayerID }

    var body: some View {
        let info = info
        HStack(alignment: .top, spacing: 0) {
            AuthorGutter(info: info, showsBars: preferences.showAuthorBars)
            VStack(alignment: .leading, spacing: 2 * textSize.scale) {
                if isTranscript {
                    TranscriptLine(document: document, block: block)
                } else {
                    NoteBlockBody(document: document, block: block)
                }
                if let mark = info.mark {
                    Text(verbatim: mark.text)
                        .font(textSize.font(.footnote))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .accessibilityHidden(true)
                }
            }
            .environment(\.noteShowsQuotes, info.showsQuotes && preferences.showQuotes)
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .padding(.trailing, 28 * textSize.scale)
    }
}

extension NoteAuthor {
    /// The gutter text: "AI", "You", "STT"; nothing for an author this version does not know.
    var gutterText: String {
        switch self {
        case .agent: "AI"
        case .human:
            String(
                localized: "document.author.you", defaultValue: "You",
                comment: "Document: author bar of a block the user wrote (the gutter label and the legend)")
        case .stt: "STT"
        default: ""
        }
    }

    /// The same, in words for VoiceOver.
    var spokenName: String {
        switch self {
        case .agent: String(localized: "Written by AI", comment: "Accessibility: who wrote a block")
        case .human: String(localized: "Written by you", comment: "Accessibility: who wrote a block")
        case .stt: String(localized: "Speech to text", comment: "Accessibility: who wrote a block")
        default: ""
        }
    }

    /// The bar's colour (prototype `.gt.ag`, `.you`, `.stt`).
    @MainActor var barColor: Color {
        switch self {
        case .agent: LintelBrand.accent
        case .human: LintelBrand.ink
        default: LintelBrand.secondaryText.opacity(0.5)
        }
    }
}

extension BlockMark {
    /// What the block says about itself (spec "Attribution and verification invariant").
    var text: String {
        switch self {
        case .revisedNotChecked:
            String(
                localized: "Revised, not checked against the recording",
                comment: "Document: an AI block that was changed after it was checked against the recording")
        case .addedByYou:
            String(localized: "Added by you", comment: "Document: a block the user wrote or edited in an AI note")
        }
    }
}

extension BlockAttributionInfo {
    /// The author in words, then the mark: what VoiceOver says at this block.
    var spokenLabel: String {
        guard let mark else { return author.spokenName }
        return "\(author.spokenName), \(mark.text)"
    }
}

struct AuthorGutter: View {
    let info: BlockAttributionInfo
    let showsBars: Bool
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        Text(verbatim: info.author.gutterText)
            .font(textSize.font(.caption1).monospaced())
            .foregroundStyle(LintelBrand.secondaryText)
            .padding(.top, 5 * textSize.scale)
            .padding(.trailing, 10)
            .frame(width: 4.2 * 12.5 * textSize.scale, alignment: .trailing)
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(info.author.barColor)
                    .frame(width: 3)
                    .padding(.vertical, 3)
            }
            // The prototype's `.noauth .gt{visibility:hidden}`: nothing is drawn, but the author stays spoken.
            .opacity(showsBars ? 1 : 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: info.spokenLabel))
    }
}

/// A quote chip (prototype `.qc`): the time of the recording a block quotes. A button that shows the transcript
/// there when the note has one.
struct QuoteChip: View {
    let document: NoteDocumentModel
    let timeMs: Int
    @Environment(\.lintelTextSize) private var textSize
    @Environment(\.noteShowsQuotes) private var showsQuotes

    var body: some View {
        let label = Text(verbatim: NoteQuote.clock(milliseconds: timeMs))
            .font(textSize.font(.footnote).monospaced())
            .foregroundStyle(LintelBrand.accentText)
            .padding(.horizontal, 6)
            .background(LintelBrand.fill, in: RoundedRectangle(cornerRadius: 4))
        if !showsQuotes {
            EmptyView()
        } else if document.transcriptLayer != nil {
            Button {
                document.jumpToTranscript(atMs: timeMs)
            } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(
                    "Show \(NoteQuote.clock(milliseconds: timeMs)) in the transcript",
                    comment: "Accessibility: a quote chip")
            )
            .accessibilityHint(Text("Switches to the transcript", comment: "Accessibility hint of a quote chip"))
        } else {
            label.accessibilityLabel(
                Text("Quoted from \(NoteQuote.clock(milliseconds: timeMs))", comment: "Accessibility: a quote time"))
        }
    }
}

/// Text from a source, drawn as inline Markdown with no link and no image, then a quote chip when its last words
/// are a time.
struct NoteInlineText: View {
    let document: NoteDocumentModel
    let text: String
    var fallbackTimesMs: [Int] = []
    var font: Font?
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        let (clean, time) = NoteQuote.split(text)
        let times = time.map { [$0] } ?? fallbackTimesMs
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(NoteInline.attributed(clean))
                .font(font ?? textSize.font(.callout))
                .foregroundStyle(LintelBrand.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ForEach(times, id: \.self) { QuoteChip(document: document, timeMs: $0) }
            Spacer(minLength: 0)
        }
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
            NoteInlineText(document: document, text: text, fallbackTimesMs: block.quoteTimesMs)
        case .list(let lines):
            VStack(alignment: .leading, spacing: 2 * textSize.scale) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    NoteListLine(
                        document: document, line: line, fallbackTimesMs: lines.count == 1 ? block.quoteTimesMs : [])
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
    let fallbackTimesMs: [Int]
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
                .frame(minWidth: 14 * textSize.scale, alignment: .trailing)
                .accessibilityHidden(true)
            NoteInlineText(document: document, text: line.text, fallbackTimesMs: fallbackTimesMs)
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
