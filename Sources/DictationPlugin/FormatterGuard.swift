import Foundation

/// Checks what the formatting model returned and throws away what is not a cleaned version of the input
/// (spec: `FormatterGuard`). A rejected chunk is replaced by the raw text, so a bad answer never reaches the
/// user's document.
///
/// Two paths (ADR 0010, "The guard"). A chunk WITHOUT a spoken retraction marker is judged by the length
/// range and the language, exactly as before the self-correction work. A chunk WITH a marker that has words
/// after it is judged by one narrow rule: the output is the whole input with the marker kept, or the input
/// minus ONE span that ends at the marker (it starts on the nearest word parallel to the replacement, or at
/// the start of the chunk for "A albo jednak B"), and nothing else changes except rewrites that cost nothing.
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
        /// A chunk with a retraction marker whose output is neither the whole input (marker kept) nor the input
        /// minus one retracted span: a lost final version, a dropped marker with both versions kept, an unsaid
        /// or swapped word, a changed number, any other edit. The raw text is pasted.
        case selfCorrection
    }

    /// The output may hold 0.6 to 1.15 times the input's words (chunks without a marker).
    static let lengthRange = 0.6...1.15

    /// The most words one retraction may remove besides its marker (the longest in the corpus is five).
    static let retractedSpanCap = 8

    /// The spoken markers with which a speaker withdraws a fragment (ADR 0010, decision 2): a closed list in
    /// Polish and English, found by code in the input, never on the model's word. Each entry is a phrase of
    /// lower-cased words.
    static let retractionMarkers: [[String]] = [
        ["czekaj"], ["jednak"], ["właściwie"], ["pomyłka"], ["przepraszam"], ["to", "znaczy"],
        ["wait"], ["actually"], ["sorry"], ["scratch", "that"], ["i", "mean"],
    ]

    /// Fillers and hesitations. A run of "y" or "e" is a hesitation however many letters the recogniser wrote.
    static let fillers: [[String]] = [
        ["um"], ["uh"], ["uhm"], ["erm"], ["eh"], ["mhm"], ["hmm"], ["no", "więc"], ["no", "cóż"], ["you", "know"],
    ]

    /// Words after which "you know" is content ("let you know", "if you know"), not a filler.
    private static let youKnowIsContentAfter: Set<String> = ["let", "if", "do", "did", "don't", "dont"]

    /// The lengths of the fillers that start at `index`.
    static func fillerLengths(_ tokens: [String], at index: Int) -> [Int] {
        var lengths: [Int] = []
        let word = tokens[index]
        if word.count >= 2, word.allSatisfy({ $0 == "y" }) || word.allSatisfy({ $0 == "e" }) { lengths.append(1) }
        for phrase in fillers where matches(tokens, phrase, at: index) {
            if phrase == ["you", "know"], index > 0, youKnowIsContentAfter.contains(tokens[index - 1]) { continue }
            lengths.append(phrase.count)
        }
        return lengths
    }

    static func check(input: String, output rawOutput: String) -> Verdict {
        let output = clean(rawOutput)
        guard !output.isEmpty else { return .rejected(.empty) }

        if answersInsteadOfCleaning(input: input, output: output) { return .rejected(.answered) }

        let spoken = tokens(input)
        if let correction = selfCorrection(in: spoken) {
            return isDerivable(spoken: spoken, written: tokens(output), correction)
                ? .accepted(output) : .rejected(.selfCorrection)
        }

        let inputWords = words(in: input)
        let outputWords = words(in: output)
        // A very short chunk can lose a filler word and so fall under the ratio by itself.
        if inputWords >= 5 {
            let ratio = Double(outputWords) / Double(inputWords)
            if ratio > lengthRange.upperBound { return .rejected(.tooLong) }
            if ratio < lengthRange.lowerBound { return .rejected(.tooShort) }
        } else if outputWords > inputWords + 3 {
            return .rejected(.tooLong)
        }

        let before = Language.dominant(in: input)
        let after = Language.dominant(in: output)
        if before != .unknown, after != .unknown, before != after { return .rejected(.languageChanged) }
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

    // MARK: A chunk with a retraction marker

    /// The first marker that has a word after it (not a filler), and the index of that word. `nil` for a chunk
    /// without one: a marker at the end retracts nothing, and the chunk is judged like any other.
    static func selfCorrection(in tokens: [String]) -> (marker: (start: Int, end: Int), first: Int)? {
        for marker in occurrences(of: retractionMarkers, in: tokens).sorted(by: { $0.end < $1.end }) {
            var first = marker.end
            while first < tokens.count, let length = fillerLengths(tokens, at: first).max() { first += length }
            if first < tokens.count { return (marker, first) }
        }
        return nil
    }

    /// The largest chunk (input words times output words) the check works on; a bigger one is refused.
    private static let derivationLimit = 10_000

    /// Whether the output is the whole input with the marker kept, or the input minus one span that ends at the
    /// marker (at most `retractedSpanCap` words, and no more than the replacement's length plus two). The span
    /// starts on the NEAREST word parallel to the first word of the replacement (the same word, two number words
    /// with a whole number taken together, "w"/"we"), so a speaker who repeats a word earlier in the sentence
    /// loses nothing before the nearest one; or at the start of the chunk when a disjunction word ("albo",
    /// "lub", "a", "or") stands right before the marker and the span holds no negation ("A albo jednak B"). The
    /// span holds at least one word that is not a filler, so a marker that opens the chunk is never dropped.
    /// Everything else, a lost or swapped word, a dropped marker with both versions kept, is refused.
    static func isDerivable(
        spoken: [String], written: [String], _ correction: (marker: (start: Int, end: Int), first: Int)
    ) -> Bool {
        guard spoken.count * written.count <= derivationLimit else { return false }
        if aligns(spoken, written) { return true }
        let marker = correction.marker
        var lead = 0
        while lead < marker.start, let length = fillerLengths(spoken, at: lead).max() { lead += length }
        guard lead < marker.start else { return false }
        let cap = min(spoken.count - marker.end + 2, retractedSpanCap, marker.start)
        var starts: [Int] = []
        if var near = stride(from: marker.start - 1, through: marker.start - cap, by: -1)
            .first(where: { parallel(spoken[$0], spoken[correction.first]) })
        {
            // A number is withdrawn as a whole: "osiemnaście tysięcy to znaczy dwadzieścia pięć tysięcy",
            // "one hundred and five".
            func isNumber(_ index: Int) -> Bool { NumberWords.value(of: [spoken[index]]) != nil }
            while near > 0, near > marker.start - cap {
                if isNumber(near), isNumber(near - 1) {
                    near -= 1
                } else if isNumber(near), near >= 2, spoken[near - 1] == "and", isNumber(near - 2) {
                    near -= 2
                } else {
                    break
                }
            }
            starts.append(near)
        }
        // From the start of the chunk only for the idiom "A albo jednak B": a disjunction word right before the
        // marker, and no negation in the span (a negation is never withdrawn silently).
        if marker.start >= 2, marker.start <= cap, disjunctions.contains(spoken[marker.start - 1]),
            !spoken[..<marker.start].contains(where: negates)
        {
            starts.append(0)
        }
        return starts.contains { start in
            aligns(Array(spoken[..<start]) + Array(spoken[marker.end...]), written)
        }
    }

    /// The words that join the two versions in "A albo jednak B", "A or actually B".
    private static let disjunctions: Set<String> = ["albo", "lub", "or", "a"]

    /// Words that negate. A span taken from the start of the chunk never holds one.
    private static let negations: Set<String> = [
        "nie", "not", "no", "never", "nigdy", "nikt", "nic", "żaden", "żadna", "żadne", "ani", "bez", "without",
        "none", "nothing", "nobody", "neither", "nor", "cannot", "nikomu", "niczego", "nigdzie",
    ]

    private static func negates(_ token: String) -> Bool {
        negations.contains(token) || token.hasSuffix("n't")
    }

    /// Whether `written` is `spoken` at no cost: every spoken word is written as the same word (equal after
    /// folding case and diacritics), as digits of an equal value, or merged into a contraction with the next
    /// one ("we are", "we're"); only a filler, or a marker that ends the chunk, may be left out; nothing is
    /// added.
    private static func aligns(_ spoken: [String], _ written: [String]) -> Bool {
        let rows = spoken.count
        let columns = written.count
        var reach = [[Bool]](repeating: [Bool](repeating: false, count: columns + 1), count: rows + 1)
        reach[0][0] = true
        for row in 0...rows {
            for column in 0...columns where reach[row][column] {
                guard row < rows else { continue }
                for length in fillerLengths(spoken, at: row) { reach[row + length][column] = true }
                if retractionMarkers.contains(where: { row + $0.count == rows && Array(spoken[row...]) == $0 }) {
                    reach[rows][column] = true
                }
                guard column < columns else { continue }
                if same(spoken[row], written[column]) { reach[row + 1][column + 1] = true }
                if row + 1 < rows, isContraction(spoken[row], spoken[row + 1], written[column]) {
                    reach[row + 2][column + 1] = true
                }
                for group in NumberWords.digitValues(in: written, at: column) {
                    for length in 1...min(9, rows - row)
                    where NumberWords.value(of: Array(spoken[row..<(row + length)])) == group.value {
                        reach[row + length][column + group.tokens] = true
                    }
                }
            }
        }
        return reach[rows][columns]
    }

    /// The same word once case and diacritics are folded ("Środa" and "środa", "Lukasz" and "Łukasz").
    private static func same(_ spoken: String, _ written: String) -> Bool {
        spoken == written || fold(spoken) == fold(written)
    }

    private static func fold(_ word: String) -> String {
        word.folding(options: .diacriticInsensitive, locale: nil).replacingOccurrences(of: "ł", with: "l")
    }

    private static let equivalentPrepositions: [Set<String>] = [["w", "we"], ["z", "ze"], ["o", "ob"]]

    /// Words that can stand in the same place of a sentence: the same word, two number words ("dwie" and
    /// "trzy"), or a preposition and its variant ("w" and "we"). The retracted span may start on such a word.
    private static func parallel(_ first: String, _ second: String) -> Bool {
        same(first, second)
            || (NumberWords.value(of: [first]) != nil && NumberWords.value(of: [second]) != nil)
            || equivalentPrepositions.contains { $0.contains(first) && $0.contains(second) }
    }

    private static let irregularContractions: [[String]: String] = [
        ["will", "not"]: "won't", ["can", "not"]: "can't", ["shall", "not"]: "shan't", ["let", "us"]: "let's",
    ]
    private static let contractionSuffixes: [String: String] = [
        "are": "'re", "is": "'s", "has": "'s", "us": "'s", "will": "'ll", "have": "'ve", "would": "'d",
        "had": "'d", "am": "'m", "not": "n't",
    ]

    /// Whether the written word is the contraction of the two spoken ones ("we are" "we're", "do not" "don't",
    /// "will not" "won't"): the first word plus a fixed ending, or one of four irregular forms.
    static func isContraction(_ first: String, _ second: String, _ written: String) -> Bool {
        guard written.contains("'") else { return false }
        if irregularContractions[[first, second]] == written { return true }
        guard let suffix = contractionSuffixes[second] else { return false }
        return written == first + suffix
    }

    private static func matches(_ tokens: [String], _ phrase: [String], at index: Int) -> Bool {
        index + phrase.count <= tokens.count && Array(tokens[index..<(index + phrase.count)]) == phrase
    }

    /// Where the marker phrases occur in the tokens, as half-open ranges.
    private static func occurrences(of phrases: [[String]], in tokens: [String]) -> [(start: Int, end: Int)] {
        tokens.indices.flatMap { index in
            phrases.filter { matches(tokens, $0, at: index) }.map { (index, index + $0.count) }
        }
    }

    static func tokens(_ text: String) -> [String] {
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

    /// "przepraszam" is both an answer opening and a retraction marker: the check is skipped when the input
    /// contains the opening itself.
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
