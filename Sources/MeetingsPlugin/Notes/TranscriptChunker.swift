import Foundation

/// One utterance of the transcript as the notes see it: who said it, when, and the plain text.
struct NotesUtterance: Equatable, Sendable {
    var startMs: Int
    var speaker: String
    var text: String

    /// The utterances of a meeting, in time order. Speaker names and text are single-line plain text, and a
    /// transcript tag in the text is removed so a speaker cannot close the `<transcript>` block of the prompt.
    static func make(from document: MeetingDocument) -> [NotesUtterance] {
        let names = Dictionary(
            document.speakers.map { ($0.id, sanitized($0.label)) }, uniquingKeysWith: { first, _ in first })
        let ordered = document.segments.enumerated().sorted {
            ($0.element.startMs, $0.element.id, $0.offset) < ($1.element.startMs, $1.element.id, $1.offset)
        }
        return ordered.compactMap { _, segment in
            let text = sanitized(segment.text)
            guard !text.isEmpty else { return nil }
            let name = segment.speakerID.flatMap { names[$0] }.flatMap { $0.isEmpty ? nil : $0 }
            return NotesUtterance(startMs: segment.startMs, speaker: name ?? "?", text: text)
        }
    }

    static func sanitized(_ text: String) -> String {
        var result = MarkdownExporter.cleaned(text, keepNewlines: false)
        // A bar would make a sentence of the transcript look like a point line (`TASK | …`) to the model.
        result = result.replacingOccurrences(of: "|", with: "/")
        result = NotesText.strippingPromptTags(result)
        return result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// `[mm:ss] Speaker: text`, the line format of a chunk.
    var line: String {
        "[\(NotesText.clock(milliseconds: startMs))] \(speaker): \(text)"
    }
}

/// A run of utterances that goes to the model in one request.
struct TranscriptChunk: Equatable, Sendable, Identifiable {
    /// The extra tokens of a line over its words: the time, the speaker and the line break.
    static let lineOverheadTokens = 8

    let id: String
    let utterances: [NotesUtterance]
    /// The language used for text too short to tell.
    let fallbackLanguage: NotesLanguage

    init(id: String, utterances: [NotesUtterance], fallbackLanguage: NotesLanguage = .unknown) {
        self.id = id
        self.utterances = utterances
        self.fallbackLanguage = fallbackLanguage
    }

    var text: String { utterances.map(\.line).joined(separator: "\n") }
    var startMs: Int { utterances.first?.startMs ?? 0 }
    var endMs: Int { utterances.last?.startMs ?? 0 }

    var estimatedTokens: Int {
        utterances.reduce(0) { $0 + Self.cost(of: $1, fallback: fallbackLanguage) }
    }

    static func cost(of utterance: NotesUtterance, fallback: NotesLanguage) -> Int {
        // The overhead covers a label of a short name; a longer one costs its extra tokens.
        let label = max(0, (utterance.speaker.count + 2) / 3 - 2)
        return lineOverheadTokens + label + NotesText.estimateTokens(utterance.text, fallback: fallback)
    }

    /// The two halves of the chunk (by utterance, or by words for a single utterance), for a request that did
    /// not fit the model's context. `nil` when the chunk is a single word.
    func split() -> [TranscriptChunk]? {
        if utterances.count >= 2 {
            let middle = utterances.count / 2
            return [
                TranscriptChunk(
                    id: id + ".1", utterances: Array(utterances[..<middle]), fallbackLanguage: fallbackLanguage),
                TranscriptChunk(
                    id: id + ".2", utterances: Array(utterances[middle...]), fallbackLanguage: fallbackLanguage),
            ]
        }
        guard let only = utterances.first else { return nil }
        let words = only.text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2 else { return nil }
        let middle = words.count / 2
        var first = only
        first.text = words[..<middle].joined(separator: " ")
        var second = only
        second.text = words[middle...].joined(separator: " ")
        return [
            TranscriptChunk(id: id + ".1", utterances: [first], fallbackLanguage: fallbackLanguage),
            TranscriptChunk(id: id + ".2", utterances: [second], fallbackLanguage: fallbackLanguage),
        ]
    }
}

/// Splits a transcript into chunks of at most `chunkTokens` estimated input tokens (default 3 000, ADR 0004
/// heuristic), cutting only between utterances and repeating the last few utterances of a chunk at the start of
/// the next so a decision at a boundary is seen whole. An utterance that alone exceeds the budget is cut at
/// sentence ends, then at words. Pure; the same input always gives the same chunks and ids (`c1`, `c2`, …).
struct TranscriptChunker: Sendable {
    static let defaultChunkTokens = 3000
    static let defaultOverlap = 3

    var chunkTokens: Int
    var overlapUtterances: Int

    init(chunkTokens: Int = Self.defaultChunkTokens, overlapUtterances: Int = Self.defaultOverlap) {
        self.chunkTokens = chunkTokens
        self.overlapUtterances = overlapUtterances
    }

    func chunks(from utterances: [NotesUtterance]) -> [TranscriptChunk] {
        let budget = max(chunkTokens, 2 * TranscriptChunk.lineOverheadTokens + 8)
        let language = NotesLanguage.dominant(in: utterances.map(\.text).joined(separator: " "))
        let pieces = utterances.flatMap { fit($0, budget: budget, fallback: language) }
        let costs = pieces.map { TranscriptChunk.cost(of: $0, fallback: language) }

        var chunks: [TranscriptChunk] = []
        var start = 0
        while start < pieces.count {
            var end = start
            var total = 0
            while end < pieces.count, total + costs[end] <= budget {
                total += costs[end]
                end += 1
            }
            // `fit` guarantees a single piece fits, so every chunk takes at least one.
            end = max(end, start + 1)
            chunks.append(
                TranscriptChunk(
                    id: "c\(chunks.count + 1)", utterances: Array(pieces[start..<end]), fallbackLanguage: language))
            guard end < pieces.count else { break }
            start = nextStart(after: start, end: end, costs: costs, budget: budget)
        }
        return chunks
    }

    /// The start of the next chunk: up to `overlapUtterances` of the previous one repeated, as long as they take
    /// at most a quarter of the budget and leave room for the next new utterance. Always moves forward.
    private func nextStart(after start: Int, end: Int, costs: [Int], budget: Int) -> Int {
        var overlap = min(max(overlapUtterances, 0), end - start - 1)
        while overlap > 0 {
            let repeated = costs[(end - overlap)..<end].reduce(0, +)
            if repeated <= budget / 4, repeated + costs[end] <= budget { break }
            overlap -= 1
        }
        return end - overlap
    }

    /// The utterance itself, or pieces of it that each fit: sentences packed up to the budget, a sentence that is
    /// still too long cut at words. The pieces keep the speaker and the start time.
    private func fit(_ utterance: NotesUtterance, budget: Int, fallback: NotesLanguage) -> [NotesUtterance] {
        func cost(_ text: String) -> Int {
            TranscriptChunk.cost(
                of: NotesUtterance(startMs: 0, speaker: utterance.speaker, text: text), fallback: fallback)
        }
        guard cost(utterance.text) > budget else { return [utterance] }

        var units: [String] = []
        for sentence in sentences(of: utterance.text) {
            if cost(sentence) <= budget {
                units.append(sentence)
            } else {
                units.append(contentsOf: wordPieces(of: sentence, fits: { cost($0) <= budget }))
            }
        }
        var pieces: [String] = []
        var current = ""
        for unit in units {
            let joined = current.isEmpty ? unit : current + " " + unit
            if cost(joined) <= budget {
                current = joined
            } else {
                if !current.isEmpty { pieces.append(current) }
                current = unit
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.map { NotesUtterance(startMs: utterance.startMs, speaker: utterance.speaker, text: $0) }
    }

    private func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let ends =
                ".!?".contains(character) && (index + 1 == characters.count || characters[index + 1].isWhitespace)
            if ends {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    /// The longest runs of words that satisfy `fits` (found by bisection); a single word always becomes a piece.
    private func wordPieces(of text: String, fits: (String) -> Bool) -> [String] {
        var rest = text.split(whereSeparator: \.isWhitespace)[...]
        var result: [String] = []
        while !rest.isEmpty {
            var low = 1
            var high = rest.count
            while low < high {
                let middle = (low + high + 1) / 2
                if fits(rest.prefix(middle).joined(separator: " ")) { low = middle } else { high = middle - 1 }
            }
            result.append(rest.prefix(low).joined(separator: " "))
            rest = rest.dropFirst(low)
        }
        return result
    }
}
