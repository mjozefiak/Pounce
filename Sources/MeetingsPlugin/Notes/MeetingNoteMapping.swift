import Foundation
import LintelCore
import LintelKit

/// Pure rules that turn a meeting row into what the Notes workspace shows.
enum MeetingNoteMapping {
    /// The state of a note (spec 2026-11-04, "Source mapping"). The meeting's own status wins unless the
    /// meeting is `ready`; then the notes decide: a running job is `writing`, a missing model with no notes is
    /// `needsModel`.
    static func state(
        status: MeetingStatus, notesStatus: NotesStatus, phase: NotesJobPhase?, needsModel: Bool
    ) -> NoteState {
        switch status {
        case .recording: return .recording
        case .processing: return .processing
        case .incomplete: return .interrupted
        case .failed: return .failed
        case .ready: break
        }
        if let phase {
            switch phase {
            case .mapping(let done, let total): return .writing(done: done, of: total)
            case .reducing: return .writing(done: 1, of: 1)
            case .queued, .waitingForModel: return .writing(done: 0, of: 0)
            }
        }
        switch notesStatus {
        case .none: return needsModel ? .needsModel : .ready
        case .ok: return .ready
        case .partial: return .partial
        case .stale: return .stale
        case .running: return .writing(done: 0, of: 0)
        case .failed: return .failed
        }
    }

    static func summary(
        _ entry: MeetingLibraryEntry, board: NotesBoard?, appName: (String) -> String?
    ) -> NoteSummary {
        let snapshot = board?.snapshot
        let title = entry.title.map(MeetingEdits.visible).flatMap { $0.isEmpty ? nil : $0 }
        return NoteSummary(
            id: NoteKey(pluginID: MeetingLibraryPresentation.pluginID, id: entry.uuid), kind: .meeting, title: title,
            startedAt: entry.startedAt, durationMs: entry.durationMs > 0 ? entry.durationMs : nil,
            sourceApp: entry.sourceBundleID.flatMap(appName).map(MeetingEdits.visible).flatMap {
                $0.isEmpty ? nil : $0
            },
            state: state(
                status: entry.status, notesStatus: entry.notesStatus, phase: snapshot?.phases[entry.id],
                needsModel: snapshot?.needsModel(for: entry.id) ?? false))
    }

    static func details(_ document: MeetingDocument) -> [NoteDetail] {
        var result: [NoteDetail] = []
        if let model = document.speechModelID.map(MeetingEdits.visible), !model.isEmpty {
            result.append(
                NoteDetail(
                    label: LocalizedStringResource(
                        "Speech model", comment: "Notes details: the model that wrote the transcript"),
                    value: model))
        }
        let audio =
            document.audioState == .spool
            ? String(localized: "Kept for recovery", comment: "Notes details: the audio of the meeting is still stored")
            : String(localized: "Deleted", comment: "Notes details: the audio of the meeting is gone")
        result.append(
            NoteDetail(
                label: LocalizedStringResource("Audio", comment: "Notes details: what is left of the recording"),
                value: audio))
        return result
    }
}

/// Finds where a search text matches in a meeting, for the explorer's snippets. Every typed word is a prefix
/// of a word of the text, like the full-text index does it; plain text only.
enum MeetingMatchLocator {
    static func words(of query: String) -> [String] {
        normalize(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(MeetingsStore.maxQueryWords)
            .map(String.init)
    }

    private static func normalize(_ text: String) -> String {
        FullTextFolding.fold(text).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// The text's words with their ranges, folded like the query.
    private static func tokens(_ text: String) -> [(word: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let isWord = character.isLetter || character.isNumber
            if isWord, start == nil { start = index }
            let next = text.index(after: index)
            if !isWord || next == text.endIndex, let from = start {
                let end = isWord ? next : index
                result.append((normalize(String(text[from..<end])), from..<end))
                start = nil
            }
            index = next
        }
        return result
    }

    /// The range of the first word that matches the first typed word, when every typed word is the prefix of a
    /// word of `text`; `nil` otherwise.
    static func match(in text: String, words: [String]) -> Range<String.Index>? {
        guard let first = words.first else { return nil }
        let tokens = tokens(text)
        guard words.allSatisfy({ word in tokens.contains { $0.word.hasPrefix(word) } }) else { return nil }
        return tokens.first { $0.word.hasPrefix(first) }?.range
    }

    /// About `radius` characters either side of the match, on one line.
    static func snippet(in text: String, around range: Range<String.Index>, radius: Int = 60) -> String {
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let body = String(text[start..<end]).split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }

    /// The matched layers and whether the title matched.
    static func matches(for document: MeetingDocument, words: [String]) -> (layers: [NoteLayerMatch], title: Bool) {
        guard !words.isEmpty else { return ([], false) }
        var layers: [NoteLayerMatch] = []
        let titleMatched = document.title.map { match(in: MeetingEdits.visible($0), words: words) != nil } ?? false
        if let notes = document.notesMarkdown {
            let text = MarkdownText.cleaned(notes, keepNewlines: false)
            if let range = match(in: text, words: words) {
                layers.append(
                    NoteLayerMatch(layerID: MeetingNoteLayers.notesLayerID, snippet: snippet(in: text, around: range)))
            }
        }
        for segment in document.segments {
            let text = MeetingEdits.visible(segment.text)
            if let range = match(in: text, words: words) {
                layers.append(
                    NoteLayerMatch(
                        layerID: MeetingNoteLayers.transcriptLayerID, snippet: snippet(in: text, around: range)))
                break
            }
        }
        return (layers, titleMatched)
    }
}
