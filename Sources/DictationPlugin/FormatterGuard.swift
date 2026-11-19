import Foundation

/// Checks what the formatting model returned and throws away what is not a cleaned version of the input
/// (spec: `FormatterGuard`). A rejected chunk is replaced by the raw text, so a bad answer never reaches the
/// user's document.
enum FormatterGuard {
    enum Verdict: Equatable, Sendable {
        case accepted(String)
        case rejected(Reason)
    }

    enum Reason: Equatable, Sendable {
        case empty
        case tooLong
        case tooShort
        case languageChanged
        case answered
        /// The output holds words the speaker never said (an unrelated or invented text), or, in a chunk that used
        /// the relaxed length bound, does not end where the input ends (a summary or a truncation).
        case addedContent
    }

    /// The output may hold 0.6 to 1.15 times the input's words.
    static let lengthRange = 0.6...1.15

    /// The lower bound for a chunk in which the speaker withdrew something or hesitated: removing a retracted
    /// fragment and its marker legitimately cuts the text by more than the ordinary bound allows ("pójdziemy
    /// na pizzę albo jednak na sushi" is 7 words, "Pójdziemy na sushi." is 3, a ratio of 0.43). The value 0.3
    /// was tuned on the synthetic self-correction corpus (its shortest correct result is 0.38), so it is only a
    /// coarse outer limit. It is not the safety mechanism: `onlyRemovesFragments` is, because it accepts a cut
    /// only where code can derive it from the input (a filler, a repetition, or a span that ends in a marker).
    static let removalFloor = 0.3

    /// For any chunk of at least five words: the share of novel words above which the output is not a cleaned
    /// version of the input but another text (an unrelated or invented answer of the right length). Generous
    /// on purpose: "obvious recognition errors" are fixed (v1 rule), so a few words do change.
    static let unrelatedShare = 0.5

    /// How many of the output's words may be absent from the input in a relaxed chunk. A cleaned text only
    /// rewrites punctuation, case, inflection and digits, so most words occur in the input; a summary, an
    /// answer or an unrelated text does not. Words with digits are not counted (the model may write "11" for
    /// "jedenastej"). The corpus' correct results add no word at all, so 0.2 only leaves room for inflection.
    static let maximumNovelShare = 0.2

    /// The spoken markers with which a speaker withdraws a fragment (ADR 0010, decision 2): a closed list in
    /// Polish and English, found by code in the input, never on the model's word. Each entry is a phrase of
    /// lower-cased words.
    static let retractionMarkers: [[String]] = [
        ["czekaj"], ["jednak"], ["właściwie"], ["pomyłka"], ["przepraszam"], ["to", "znaczy"],
        ["wait"], ["actually"], ["sorry"], ["scratch", "that"], ["i", "mean"],
    ]

    /// Fillers and hesitations, which also shorten the text by themselves.
    static let fillers: [[String]] = [
        ["yyy"], ["yy"], ["eee"], ["ee"], ["um"], ["uh"], ["uhm"], ["hmm"], ["no", "więc"], ["no", "cóż"],
        ["you", "know"],
    ]

    static func check(input: String, output rawOutput: String) -> Verdict {
        let output = clean(rawOutput)
        guard !output.isEmpty else { return .rejected(.empty) }

        if answersInsteadOfCleaning(input: input, output: output) { return .rejected(.answered) }

        let inputWords = words(in: input)
        let outputWords = words(in: output)
        // A very short chunk can lose a filler word and so fall under the ratio by itself.
        // The bound drops only for a chunk in which the speaker withdrew or hesitated, and then the output must
        // still be made of the input's words and end where the input ends.
        var usesRelaxedBound = false
        if inputWords >= 5 {
            let ratio = Double(outputWords) / Double(inputWords)
            if ratio > lengthRange.upperBound { return .rejected(.tooLong) }
            if ratio < lengthRange.lowerBound {
                // Only a chunk with a marker or a filler may be this short, and only down to the floor.
                guard containsRemovable(input), ratio >= removalFloor else { return .rejected(.tooShort) }
                usesRelaxedBound = true
            }
        } else if outputWords > inputWords + 3 {
            return .rejected(.tooLong)
        }
        let before = Language.dominant(in: input)
        let after = Language.dominant(in: output)
        if before != .unknown, after != .unknown, before != after { return .rejected(.languageChanged) }
        if usesRelaxedBound, !onlyRemovesFragments(input: input, output: output) {
            return .rejected(.addedContent)
        }
        // Another text of the right length: checked last so a changed language keeps its own reason.
        if inputWords >= 5, novelShare(input: input, output: output) > unrelatedShare {
            return .rejected(.addedContent)
        }
        return .accepted(output)
    }

    /// Removes thinking blocks and tags the model may echo, and the whitespace around the text.
    static func clean(_ text: String) -> String {
        var result = text
        // A reasoning block, closed or (when the model ran out of tokens) open to the end.
        while let open = result.range(of: "<think>") {
            if let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
            }
        }
        // A template that opens the block itself leaves only the closing tag.
        if let close = result.range(of: "</think>", options: .backwards) {
            result.removeSubrange(result.startIndex..<close.upperBound)
        }
        for tag in ["<transcript>", "</transcript>", "<context>", "</context>"] {
            result = result.replacingOccurrences(of: tag, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the input holds a retraction marker or a filler from the closed lists.
    static func containsRemovable(_ input: String) -> Bool {
        let tokens = tokens(input)
        return (retractionMarkers + fillers).contains { contains(tokens, phrase: $0) }
    }

    /// The most edits (substitutions, insertions, deletions that are not derivable from the input) a relaxed
    /// chunk may need: two for inflection and punctuation-like slips, or a fifth of the output's words.
    static func editBudget(outputWords: Int) -> Int {
        max(2, Int((0.2 * Double(outputWords)).rounded(.up)))
    }

    /// The largest chunk (input words times output words) the derivation check works on; a bigger one is
    /// refused, which makes the chunk fall back to the raw text.
    private static let derivationLimit = 4_000_000

    /// For a relaxed chunk: the output is the input with only the removals the closed lists allow, and keeps
    /// the input's last word, so it is not a summary, a cut middle or another text.
    ///
    /// The output must be derivable from the input at a small cost (`editBudget`). Free removals: a filler, an
    /// immediate repetition (up to four words), a stutter (a word that is a proper prefix of the next one), and
    /// a span that ENDS in a retraction marker (the retracted words before the marker and the marker itself),
    /// when the retracted part is not longer than the words the speaker said after the marker (up to the next
    /// marker) plus two. A word with digits in the output may stand for one to four spoken words (a number
    /// written as digits) or be inserted. Any other difference costs one per word.
    static func onlyRemovesFragments(input: String, output: String) -> Bool {
        let spoken = tokens(input)
        let written = tokens(output)
        guard let lastSpoken = spoken.last, let lastWritten = written.last else { return false }
        if novelShare(input: input, output: output) > maximumNovelShare { return false }
        guard lastWritten == lastSpoken || lastWritten.contains(where: \.isNumber) else { return false }
        return derivationCost(spoken: spoken, written: written) <= editBudget(outputWords: written.count)
    }

    /// The cheapest way to turn `spoken` into `written` (see `onlyRemovesFragments`); `Int.max` when the
    /// chunk is too large to check.
    static func derivationCost(spoken: [String], written: [String]) -> Int {
        let rows = spoken.count + 1
        let columns = written.count + 1
        guard rows * columns <= derivationLimit else { return Int.max }
        let infinity = Int.max / 2

        // Free removals from each input position: (end index) of a span deleted at no cost.
        var freeEnds = [[Int]](repeating: [], count: rows)
        let markers = occurrences(of: retractionMarkers, in: spoken)
        for index in 0..<spoken.count {
            for phrase in fillers where matches(spoken, phrase, at: index) {
                freeEnds[index].append(index + phrase.count)
            }
            for length in 1...4 where index + 2 * length <= spoken.count {
                if spoken[index..<(index + length)] == spoken[(index + length)..<(index + 2 * length)] {
                    freeEnds[index].append(index + length)
                }
            }
            if index + 1 < spoken.count, spoken[index] != spoken[index + 1],
                spoken[index + 1].hasPrefix(spoken[index])
            {
                freeEnds[index].append(index + 1)
            }
        }
        for marker in markers {
            let nextStart = markers.map(\.start).filter { $0 >= marker.end }.min() ?? spoken.count
            let after = nextStart - marker.end
            for start in stride(from: marker.start, through: 0, by: -1) where marker.start - start <= after + 2 {
                freeEnds[start].append(marker.end)
            }
        }

        var cost = [Int](repeating: infinity, count: rows * columns)
        cost[0] = 0
        func relax(_ row: Int, _ column: Int, _ value: Int) {
            let slot = row * columns + column
            if value < cost[slot] { cost[slot] = value }
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let here = cost[row * columns + column]
                if here >= infinity { continue }
                if row < spoken.count {
                    relax(row + 1, column, here + 1)
                    for end in freeEnds[row] { relax(end, column, here) }
                }
                if column < written.count {
                    let hasDigit = written[column].contains(where: \.isNumber)
                    relax(row, column + 1, here + (hasDigit ? 0 : 1))
                    if row < spoken.count {
                        relax(row + 1, column + 1, here + (spoken[row] == written[column] ? 0 : 1))
                        if hasDigit {
                            for length in 1...4 where row + length <= spoken.count {
                                relax(row + length, column + 1, here)
                            }
                        }
                    }
                }
            }
        }
        return cost[rows * columns - 1]
    }

    private static func matches(_ tokens: [String], _ phrase: [String], at index: Int) -> Bool {
        index + phrase.count <= tokens.count && Array(tokens[index..<(index + phrase.count)]) == phrase
    }

    /// Where the marker phrases occur in the tokens, as half-open ranges.
    private static func occurrences(of phrases: [[String]], in tokens: [String]) -> [(start: Int, end: Int)] {
        var found: [(start: Int, end: Int)] = []
        for index in 0..<tokens.count {
            for phrase in phrases where matches(tokens, phrase, at: index) {
                found.append((index, index + phrase.count))
            }
        }
        return found
    }

    /// The share of the output's words (digits not counted) that the input does not hold.
    static func novelShare(input: String, output: String) -> Double {
        let known = Set(tokens(input))
        let counted = tokens(output).filter { !$0.contains(where: \.isNumber) }
        guard !counted.isEmpty else { return 0 }
        return Double(counted.filter { !known.contains($0) }.count) / Double(counted.count)
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }

    private static func contains(_ tokens: [String], phrase: [String]) -> Bool {
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return false }
        return (0...(tokens.count - phrase.count)).contains { Array(tokens[$0..<($0 + phrase.count)]) == phrase }
    }

    static func words(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static let answerOpenings = [
        "oto ", "oczywiście", "jasne,", "jasne!", "sure,", "sure!", "sure.", "certainly", "of course",
        "here is", "here's", "here are", "i can't", "i cannot", "as an ai", "przepraszam",
    ]

    private static func answersInsteadOfCleaning(input: String, output: String) -> Bool {
        let lower = output.lowercased()
        let spoken = input.lowercased()
        return answerOpenings.contains {
            lower.hasPrefix($0) && !spoken.contains($0.trimmingCharacters(in: .punctuationCharacters))
        }
    }
}

/// A rough language detector for the guard: Polish or English, by diacritics and common words. It only has
/// to notice that a whole chunk changed language, so `unknown` is a fine answer for short or mixed text.
enum Language: Equatable, Sendable {
    case polish, english, unknown

    private static let polishWords: Set<String> = [
        "i", "w", "z", "na", "nie", "że", "się", "to", "jest", "do", "jak", "ale", "co", "po", "czy", "tak",
        "już", "go", "ma", "by", "bo", "dla", "tego", "jeszcze", "tylko", "przez", "mam", "będzie", "może",
        "który", "która", "które", "tym", "więc", "też", "oraz",
    ]
    private static let englishWords: Set<String> = [
        "the", "and", "of", "to", "in", "is", "that", "it", "for", "was", "on", "are", "with", "as", "this",
        "be", "at", "have", "from", "or", "an", "not", "we", "you", "but", "will", "should", "would", "can",
    ]

    static func dominant(in text: String) -> Language {
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
}
