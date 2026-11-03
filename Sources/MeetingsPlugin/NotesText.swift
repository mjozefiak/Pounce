import Foundation
import PounceCore

/// A rough language detector for the notes: Polish or English, by diacritics and common words. A copy of the
/// dictation guard's detector (plugins never import each other). `unknown` is the answer for short or mixed text.
enum NotesLanguage: Equatable, Sendable {
    case polish, english, unknown

    /// Output tokens per word with the Qwen3 tokenizer (ADR 0004). Unknown text is counted as Polish: the budget
    /// errs on the side of a smaller chunk.
    static let polishTokensPerWord = 2.69
    static let englishTokensPerWord = 1.17

    private static let polishWords: Set<String> = [
        "i", "w", "z", "na", "nie", "że", "się", "to", "jest", "do", "jak", "ale", "co", "po", "czy", "tak",
        "już", "go", "ma", "by", "bo", "dla", "tego", "jeszcze", "tylko", "przez", "mam", "będzie", "może",
        "który", "która", "które", "tym", "więc", "też", "oraz",
    ]
    private static let englishWords: Set<String> = [
        "the", "and", "of", "to", "in", "is", "that", "it", "for", "was", "on", "are", "with", "as", "this",
        "be", "at", "have", "from", "or", "an", "not", "we", "you", "but", "will", "should", "would", "can",
    ]

    static func dominant(in text: String) -> NotesLanguage {
        let tokens = text.lowercased().split { !$0.isLetter }.map(String.init)
        guard tokens.count >= 4 else { return .unknown }
        var polish = 0
        var english = 0
        for token in tokens {
            if polishWords.contains(token) { polish += 1 }
            if englishWords.contains(token) { english += 1 }
            if token.contains(where: { "ąćęłńóśźż".contains($0) }) { polish += 2 }
        }
        if polish >= english + 2 { return .polish }
        if english >= polish + 2 { return .english }
        return .unknown
    }

    var tokensPerWord: Double {
        self == .english ? Self.englishTokensPerWord : Self.polishTokensPerWord
    }
}

/// Text helpers shared by the chunker, the pipeline and the guard. Pure.
enum NotesText {
    // MARK: Model output

    /// Removes what a model may wrap around its answer: reasoning blocks (closed, or open to the end when it ran
    /// out of tokens), the closing tag left by a template that opens the block itself, code fences and echoed
    /// transcript tags.
    static func clean(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>") {
            if let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
            }
        }
        if let close = result.range(of: "</think>", options: .backwards) {
            result.removeSubrange(result.startIndex..<close.upperBound)
        }
        for tag in ["<transcript>", "</transcript>", "<points>", "</points>", "<summaries>", "</summaries>"] {
            result = result.replacingOccurrences(of: tag, with: "", options: .caseInsensitive)
        }
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Words

    /// The normalised letters-and-digits words of a text (lowercase, no diacritics, `ł` → `l`).
    static func words(_ text: String) -> [String] {
        TextNormalizer.normalize(text).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// Two normalised words are the same word, allowing for a Polish or English ending: both at least 5 letters
    /// long, sharing at least 4 and differing in at most 3 trailing letters (`piątek`/`piątku`,
    /// `spotkanie`/`spotkaniu`). A word with a digit must be equal. `Kowalski`/`Kowalczyk` do not match.
    static func wordsMatch(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        let a = Array(first)
        let b = Array(second)
        guard a.count >= 5, b.count >= 5 else { return false }
        if a.contains(where: \.isNumber) || b.contains(where: \.isNumber) { return false }
        var shared = 0
        while shared < min(a.count, b.count), a[shared] == b[shared] { shared += 1 }
        return shared >= 4 && max(a.count, b.count) - shared <= 3
    }

    // MARK: Tokens

    /// The estimate of the model tokens of `text` (ADR 0004 heuristic). `fallback` is used when the text is too
    /// short to tell its language.
    static func estimateTokens(_ text: String, fallback: NotesLanguage = .unknown) -> Int {
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words > 0 else { return 0 }
        var language = NotesLanguage.dominant(in: text)
        if language == .unknown { language = fallback }
        return Int((Double(words) * language.tokensPerWord).rounded(.up))
    }

    // MARK: Clock

    /// `mm:ss`, the minutes growing past two digits for a long meeting.
    static func clock(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// `mm:ss` or `h:mm:ss` to milliseconds.
    static func parseClock(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(
            separator: ":", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, (2...3).contains(numbers.count), numbers.allSatisfy({ $0 >= 0 }) else {
            return nil
        }
        let seconds =
            numbers.count == 3 ? numbers[0] * 3600 + numbers[1] * 60 + numbers[2] : numbers[0] * 60 + numbers[1]
        return seconds * 1000
    }

    /// The text up to and including its first sentence end, capped at `limit` characters at a word boundary.
    static func firstSentence(_ text: String, limit: Int = 240) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var end = flat.endIndex
        var index = flat.startIndex
        while index < flat.endIndex {
            let character = flat[index]
            let next = flat.index(after: index)
            if ".!?".contains(character), next == flat.endIndex || flat[next].isWhitespace {
                end = next
                break
            }
            index = next
        }
        return truncated(String(flat[flat.startIndex..<end]), limit: limit)
    }

    /// At most `limit` characters, cut at a word boundary.
    static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let space = head.lastIndex(where: \.isWhitespace) {
            return String(head[head.startIndex..<space]).trimmingCharacters(in: .whitespaces)
        }
        return head
    }
}
