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
        /// The output holds words the speaker never said (an unrelated or invented text), or a replacement the
        /// speaker said after a retraction was dropped or swapped for another word.
        case addedContent
        /// A chunk with a retraction or filler does not end where the input ends (a truncation or a summary).
        case endChanged
    }

    /// The output may hold 0.6 to 1.15 times the input's words.
    static let lengthRange = 0.6...1.15

    /// The hard floor for a chunk in which the speaker withdrew something or hesitated. The real bound is
    /// `lowerBound(inputWords:allowance:)`; this value only stops it from going lower.
    static let removalFloor = 0.3

    /// How many words one retraction may remove besides its marker (the longest retracted span in the
    /// corpus is five); the same cap bounds the free span in `derivationCost`.
    static let retractedSpanCap = 8

    /// The fewest output words a chunk may have: `min(0.6 x input, input - allowance)`, never below 0.3 x input.
    /// The allowance is what the closed lists can explain: the words of every filler and marker, and up to
    /// `retractedSpanCap` retracted words per marker. A filler alone therefore does not lower the bound of a
    /// 60-word chunk, and a retraction lowers it by at most a few words, whatever the chunk length.
    static func lowerBound(inputWords: Int, allowance: Int) -> Double {
        let ordinary = lengthRange.lowerBound * Double(inputWords)
        let explained = Double(inputWords - allowance)
        return max(removalFloor * Double(inputWords), min(ordinary, explained))
    }

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
    /// A run of "y" or "e" is a hesitation however many letters the recogniser wrote ("yy", "yyyy", "eeee").
    static let fillers: [[String]] = [
        ["um"], ["uh"], ["uhm"], ["erm"], ["eh"], ["mhm"], ["hmm"], ["no", "więc"], ["no", "cóż"], ["you", "know"],
    ]

    /// Words after which "you know" is content ("let you know", "if you know", "do you know"), not a filler.
    private static let youKnowIsContentAfter: Set<String> = ["let", "if", "do", "did", "don't", "dont"]

    /// The lengths of the fillers that start at `index`.
    static func fillerLengths(_ tokens: [String], at index: Int) -> [Int] {
        var lengths: [Int] = []
        let word = tokens[index]
        if word.count >= 2, word.allSatisfy({ $0 == "y" }) || word.allSatisfy({ $0 == "e" }) {
            lengths.append(1)
        }
        for phrase in fillers where matches(tokens, phrase, at: index) {
            if phrase == ["you", "know"], index > 0, youKnowIsContentAfter.contains(tokens[index - 1]) { continue }
            lengths.append(phrase.count)
        }
        return lengths
    }

    /// Where the fillers occur in the tokens, as half-open ranges.
    private static func fillerOccurrences(in tokens: [String]) -> [(start: Int, end: Int)] {
        tokens.indices.flatMap { index in fillerLengths(tokens, at: index).map { (index, index + $0) } }
    }

    static func check(input: String, output rawOutput: String) -> Verdict {
        let output = clean(rawOutput)
        guard !output.isEmpty else { return .rejected(.empty) }

        if answersInsteadOfCleaning(input: input, output: output) { return .rejected(.answered) }

        let inputWords = words(in: input)
        let outputWords = words(in: output)
        let spoken = tokens(input)
        let written = tokens(output)
        // A very short chunk can lose a filler word and so fall under the ratio by itself. The bound drops only
        // by what the closed lists explain, and then the output must still be derivable from the input.
        var usesRelaxedBound = false
        if inputWords >= 5 {
            let ratio = Double(outputWords) / Double(inputWords)
            if ratio > lengthRange.upperBound { return .rejected(.tooLong) }
            if ratio < lengthRange.lowerBound {
                let allowance = removableAllowance(spoken)
                guard allowance > 0,
                    Double(outputWords) >= lowerBound(inputWords: inputWords, allowance: allowance)
                else { return .rejected(.tooShort) }
                usesRelaxedBound = true
            }
        } else if outputWords > inputWords + 3 {
            return .rejected(.tooLong)
        }
        let before = Language.dominant(in: input)
        let after = Language.dominant(in: output)
        if before != .unknown, after != .unknown, before != after { return .rejected(.languageChanged) }
        // Every chunk of five words or more must be derivable from the input: a marker that is not on the list
        // ("a nie", "znaczy", "or rather") otherwise lets a deleted final version pass the ratio check.
        if inputWords >= 5 || usesRelaxedBound || replacementStart(spoken) != nil {
            if usesRelaxedBound, novelShare(input: input, output: output) > maximumNovelShare {
                return .rejected(.addedContent)
            }
            if !endsWhereInputEnds(spoken: spoken, written: written) { return .rejected(.endChanged) }
            if derivationCost(spoken: spoken, written: written) > editBudget(outputWords: written.count) {
                return .rejected(.addedContent)
            }
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

    /// The words of the fillers and markers in the tokens, plus `retractedSpanCap` per marker: how many
    /// words the closed lists can account for. Zero when the chunk holds none.
    static func removableAllowance(_ tokens: [String]) -> Int {
        let fillerWords = fillerOccurrences(in: tokens).reduce(0) { $0 + $1.end - $1.start }
        let markers = occurrences(of: retractionMarkers, in: tokens)
        let markerWords = markers.reduce(0) { $0 + $1.end - $1.start }
        return fillerWords + markerWords + markers.count * retractedSpanCap
    }

    /// Where the replacement starts: the end of the FIRST marker occurrence that has words after it; `nil`
    /// when the chunk has no marker or every marker is at the end. A later marker ("sorry", "jednak" as an
    /// apology or a hedge) sits inside the replacement and must not move its start past the real correction.
    static func replacementStart(_ tokens: [String]) -> Int? {
        occurrences(of: retractionMarkers, in: tokens).map(\.end).filter { $0 < tokens.count }.min()
    }

    /// The most edits (substitutions, insertions, deletions that are not derivable from the input) a chunk
    /// may need: two for inflection and punctuation-like slips, or a tenth of the output's words.
    static func editBudget(outputWords: Int) -> Int {
        max(2, Int((0.1 * Double(outputWords)).rounded(.up)))
    }

    /// The largest chunk (input words times output words) the derivation check works on; a bigger one is
    /// refused, which makes the chunk fall back to the raw text.
    private static let derivationLimit = 4_000_000

    /// Whether `word` is a near form of `other`: the same word with another ending or recognition spelling.
    /// One rule: equal after folding case and diacritics, or a shared prefix of at least four letters that is
    /// at least 60% of the shorter word ("Marka" for "Mark", "sztuki" for "sztuk", but not "Nowak" for
    /// "Nowicki"). Anything shorter than four letters must match exactly.
    static func isNearForm(_ word: String, _ other: String) -> Bool {
        if word == other { return true }
        // Two number words of different value are different numbers ("sześćset" and "sześćdziesiąt").
        if let x = NumberWords.value(of: [word]), let y = NumberWords.value(of: [other]), x != y { return false }
        let a = word.folding(options: .diacriticInsensitive, locale: nil).replacingOccurrences(of: "ł", with: "l")
        let b = other.folding(options: .diacriticInsensitive, locale: nil).replacingOccurrences(of: "ł", with: "l")
        if a == b { return true }
        let shared = zip(a, b).prefix { $0 == $1 }.count
        let shorter = min(a.count, b.count)
        return shared >= 4 && Double(shared) >= 0.6 * Double(shorter)
    }

    /// The length of the marker or filler the tokens end on, if any.
    private static func trailingRemovable(_ tokens: [String]) -> Int? {
        for phrase in retractionMarkers
        where tokens.count >= phrase.count && Array(tokens.suffix(phrase.count)) == phrase {
            return phrase.count
        }
        for length in 1...min(2, tokens.count) where fillerLengths(tokens, at: tokens.count - length).contains(length) {
            return length
        }
        return nil
    }

    /// The input's last word that is not a trailing filler or marker.
    static func effectiveSpoken(_ spoken: [String]) -> [String] {
        var tokens = spoken
        var changed = true
        while changed, !tokens.isEmpty {
            changed = false
            if let length = trailingRemovable(tokens) {
                tokens.removeLast(length)
                changed = true
            }
        }
        return tokens.isEmpty ? spoken : tokens
    }

    /// The output's last word is the input's last word (not counting a trailing filler or marker), a near
    /// form of it, or digits whose value equals the number words the input ends on.
    static func endsWhereInputEnds(spoken: [String], written fullWritten: [String]) -> Bool {
        // A clock time written "15:00" ends in "00", which only says "o'clock" for the hour before it.
        var written = fullWritten
        if written.count >= 2, written.last == "00", NumberWords.value(ofDigits: written[written.count - 2]) != nil {
            written.removeLast()
        }
        let core = effectiveSpoken(spoken)
        guard let lastSpoken = core.last, let lastWritten = written.last else { return false }
        if isNearForm(lastWritten, lastSpoken) { return true }
        var values: [Int] = []
        if let single = NumberWords.value(ofDigits: lastWritten) { values.append(single) }
        if written.count >= 2, lastWritten.count == 3 {
            for length in 2...min(3, written.count) {
                let start = written.count - length
                if let match = NumberWords.digitValues(in: written, at: start).first(where: { $0.tokens == length }) {
                    values.append(match.value)
                }
            }
        }
        for length in 1...min(9, core.count) {
            if let spokenValue = NumberWords.value(of: Array(core.suffix(length))), values.contains(spokenValue) {
                return true
            }
        }
        return false
    }

    /// The cheapest way to turn `spoken` into `written`; `Int.max` when the chunk is too large to check.
    ///
    /// Free (cost 0): a filler, an immediate repetition (up to four words), a stutter (a word that is a proper
    /// prefix of the next one, unless it is a number word), a span that ENDS in a retraction marker (the
    /// retracted words before it and the marker itself) when the retracted part is at most `min(words after
    /// the marker, up to the next marker + 2, retractedSpanCap)`, and a digit word standing for number words
    /// of EQUAL value. A marker with no words after it, or inside the replacement, frees only its own phrase.
    /// Cost one: any other inserted, deleted or different word before the replacement. In the replacement
    /// (after the first marker that has words after it) a spoken word may only be matched, removed as a
    /// filler, repetition or stutter, replaced by a word that does not bring back a word of the withdrawn
    /// part (a near form of it, or a word the speaker did not say), or absorbed by an equal-valued digit:
    /// never deleted.
    static func derivationCost(spoken: [String], written: [String]) -> Int {
        let rows = spoken.count + 1
        let columns = written.count + 1
        guard rows * columns <= derivationLimit else { return Int.max }
        let infinity = Int.max / 2
        let tailStart = replacementStart(spoken) ?? spoken.count
        // In the replacement a written word may stand for a spoken one (a recognition fix, an inflection) as
        // long as it does not bring back a word of the withdrawn part: not equal to, and not a near form of,
        // a word before the replacement that the replacement does not also say. Digits only by equal value.
        let tailWords = Set(spoken[min(tailStart, spoken.count)...])
        let withdrawnWords = Set(spoken[..<min(tailStart, spoken.count)]).subtracting(tailWords)
        let spokenWords = Set(spoken)
        func isNumber(_ word: String) -> Bool {
            word.contains(where: \.isNumber) || NumberWords.value(of: [word]) != nil
        }
        func bringsBack(_ word: String) -> Bool {
            if word.contains(where: \.isNumber) { return true }
            return withdrawnWords.contains { $0 == word || isNearForm($0, word) }
        }

        var freeEnds = [[Int]](repeating: [], count: rows)
        let markers = occurrences(of: retractionMarkers, in: spoken)
        for index in 0..<spoken.count {
            for length in fillerLengths(spoken, at: index) { freeEnds[index].append(index + length) }
            for length in 1...4 where index + 2 * length <= spoken.count {
                if spoken[index..<(index + length)] == spoken[(index + length)..<(index + 2 * length)] {
                    freeEnds[index].append(index + length)
                }
            }
            if index + 1 < spoken.count, spoken[index] != spoken[index + 1],
                spoken[index + 1].hasPrefix(spoken[index]),
                // "pięć pięćdziesiąt" is 5,50: the first number word is not a stutter.
                NumberWords.value(of: [spoken[index]]) == nil
            {
                freeEnds[index].append(index + 1)
            }
        }
        for marker in markers {
            let nextStart = markers.map(\.start).filter { $0 >= marker.end }.min() ?? spoken.count
            let after = nextStart - marker.end
            // A marker with no words after it retracts nothing, and a marker inside the replacement licenses
            // no retracted span: only its own phrase is free.
            let allowed = marker.start >= tailStart || after == 0 ? 0 : min(after + 2, retractedSpanCap, marker.start)
            for start in stride(from: marker.start, through: 0, by: -1) where marker.start - start <= allowed {
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
                    if row < tailStart { relax(row + 1, column, here + 1) }
                    for end in freeEnds[row] { relax(end, column, here) }
                }
                guard column < written.count else { continue }
                relax(row, column + 1, here + 1)
                guard row < spoken.count else { continue }
                if spoken[row] == written[column] {
                    relax(row + 1, column + 1, here)
                } else if row < tailStart
                    || (!bringsBack(written[column])
                        && (isNearForm(spoken[row], written[column])
                            || (!spokenWords.contains(written[column]) && !isNumber(spoken[row])
                                && !isNumber(written[column]))))
                {
                    // In the replacement: a near form of the spoken word, or a word the speaker did not say
                    // (a contraction, a recognition fix) that is not a number and does not replace one; never
                    // a word of the withdrawn part and never a duplicate of another spoken word, which would
                    // hide a dropped word.
                    relax(row + 1, column + 1, here + 1)
                }
                for group in NumberWords.digitValues(in: written, at: column) {
                    for length in 1...min(9, spoken.count - row)
                    where NumberWords.value(of: Array(spoken[row..<(row + length)])) == group.value {
                        relax(row + length, column + group.tokens, here)
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
