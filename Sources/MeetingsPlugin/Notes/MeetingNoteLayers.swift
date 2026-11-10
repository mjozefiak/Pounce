import CryptoKit
import Foundation
import LintelCore
import LintelKit

/// A meeting as the Notes workspace reads it: two layers, `notes` (written by the notes model, author `agent`)
/// and `transcript` (speech to text, author `stt`). Pure: no store, no I/O.
///
/// The transcript is Markdown with one block per segment that has visible text, in time order, holding only
/// that segment's text (escaped, on one line, so `MarkdownBlocks.split` gives back exactly one block per
/// segment). Who spoke, when and which segment it was ride in `NoteBlockProvenance`. Each layer's `version` is
/// a SHA-256 of its text and its provenance WITHOUT the speaker ids: renaming a speaker, or a second
/// `applySpeakerPlan` that gives the same segments new speaker rows, does not change it.
enum MeetingNoteLayers {
    static let notesLayerID = "notes"
    static let transcriptLayerID = "transcript"

    /// The notes, `nil` when there is no text. Each block that ends with the time of its quote (`[mm:ss]`, as
    /// `NotesComposer` writes it) carries that time in `quoteTimesMs`.
    static func notesLayer(_ document: MeetingDocument) -> NoteLayer? {
        guard let raw = document.notesMarkdown else { return nil }
        let markdown = MarkdownText.cleaned(raw, keepNewlines: true).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }
        let provenance = MarkdownBlocks.split(markdown).enumerated().compactMap {
            index, block -> NoteBlockProvenance? in
            guard let time = quoteTime(in: block) else { return nil }
            return NoteBlockProvenance(blockIndex: index, quoteTimesMs: [time])
        }
        return NoteLayer(
            id: notesLayerID, author: .agent, markdown: markdown, provenance: provenance,
            version: version(markdown: markdown, provenance: provenance))
    }

    /// The transcript, `nil` when no segment has visible text.
    static func transcriptLayer(_ document: MeetingDocument) -> NoteLayer? {
        let ordered = document.segments.enumerated().sorted {
            ($0.element.startMs, $0.element.id, $0.offset) < ($1.element.startMs, $1.element.id, $1.offset)
        }
        var blocks: [String] = []
        var provenance: [NoteBlockProvenance] = []
        for (_, segment) in ordered {
            let text = MeetingEdits.visible(segment.text)
            guard !text.isEmpty else { continue }
            provenance.append(
                NoteBlockProvenance(
                    blockIndex: blocks.count, speakerID: segment.speakerID.map(String.init), startMs: segment.startMs,
                    segmentRef: String(segment.id)))
            blocks.append(MarkdownExporter.escape(text))
        }
        guard !blocks.isEmpty else { return nil }
        let markdown = blocks.joined(separator: "\n\n")
        return NoteLayer(
            id: transcriptLayerID, author: .stt, markdown: markdown, provenance: provenance,
            version: version(markdown: markdown, provenance: provenance))
    }

    static func layers(_ document: MeetingDocument) -> [NoteLayer] {
        [notesLayer(document), transcriptLayer(document)].compactMap { $0 }
    }

    /// Id, shown name and "is me" of every speaker row. The ids are the rows' own and may change when the
    /// speakers are assigned again; a block's `segmentRef` is the stable link.
    static func speakers(_ document: MeetingDocument) -> [NoteSpeaker] {
        document.speakers.map {
            NoteSpeaker(id: String($0.id), name: MeetingEdits.visible($0.label), isSelf: $0.isSelf)
        }
    }

    /// SHA-256 of the markdown and of the provenance without speaker ids, hex.
    static func version(markdown: String, provenance: [NoteBlockProvenance]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(markdown.utf8))
        for block in provenance {
            let line =
                "\u{1}\(block.blockIndex)|\(block.quoteTimesMs.map(String.init).joined(separator: ","))|\(block.startMs.map(String.init) ?? "")|\(block.segmentRef ?? "")"
            hasher.update(data: Data(line.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The time in a trailing `[mm:ss]` or `[h:mm:ss]` (the composer escapes the brackets as `\[` and `\]`).
    static func quoteTime(in block: String) -> Int? {
        guard let match = block.firstMatch(of: /\\?\[([0-9:\\]{3,24})\\?\]\s*$/) else { return nil }
        return NotesText.parseClock(String(match.output.1).replacing("\\", with: ""))
    }
}
