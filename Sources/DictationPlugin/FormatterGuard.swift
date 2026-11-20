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
        /// A word the speaker said after a retraction marker (the final version) is missing from the output, or
        /// another word stands in its place. Logged by name only, so a fallback can be told from `addedContent`.
        case replacementLost
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
        // ("no", "a nie", "znaczy", "or rather") otherwise lets a deleted final version pass the ratio check.
        // The derivation lets the harmless rewrites of an ordinary cleanup through at no cost (punctuation,
        // case, contractions, digits for number words, "%", "zł", "OK", a dropped trailing "no").
        if inputWords >= 5 || usesRelaxedBound || replacementStart(spoken) != nil {
            if usesRelaxedBound, novelShare(input: input, output: output) > maximumNovelShare {
                return .rejected(.addedContent)
            }
            if !endsWhereInputEnds(spoken: spoken, written: written) { return .rejected(.endChanged) }
            if markerDroppedWithWithdrawnKept(spoken: spoken, written: written) { return .rejected(.replacementLost) }
            if derivationCost(spoken: spoken, written: written) > editBudget(outputWords: written.count) {
                return .rejected(
                    replacementSurvives(spoken: spoken, written: written) ? .addedContent : .replacementLost)
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

    /// Whether every word of the replacement (the words after the first marker with words after it) that is not
    /// a filler is in the output, as the same word, a near form, or a digit token for a number word. `true`
    /// for a chunk without a replacement. Only names the rejection reason; it never accepts anything.
    private static func replacementSurvives(spoken: [String], written: [String]) -> Bool {
        guard let start = replacementStart(spoken) else { return true }
        var index = start
        while index < spoken.count {
            if let length = fillerLengths(spoken, at: index).max() {
                index += length
                continue
            }
            let word = spoken[index]
            let present =
                written.contains { isNearForm($0, word) }
                || (NumberWords.value(of: [word]) != nil && written.contains { $0.contains(where: \.isNumber) })
            if !present { return false }
            index += 1
        }
        return true
    }

    /// The most edits (substitutions, insertions, deletions that are not derivable from the input) a chunk
    /// may need: two for inflection and punctuation-like slips, or a tenth of the output's words.
    static func editBudget(outputWords: Int) -> Int {
        max(2, Int((0.1 * Double(outputWords)).rounded(.up)))
    }

    /// The largest chunk (input words times output words) the derivation check works on; a bigger one is
    /// refused, which makes the chunk fall back to the raw text.
    private static let derivationLimit = 10_000

    /// Whether `word` is a near form of `other`: the same word with another ending or recognition spelling.
    /// One rule: equal after folding case and diacritics, or a shared prefix of at least four letters that is
    /// at least 60% of the shorter word ("Marka" for "Mark", "sztuki" for "sztuk", but not "Nowak" for
    /// "Nowicki"). Anything shorter than four letters must match exactly.
    static func isNearForm(_ word: String, _ other: String) -> Bool {
        if word == other { return true }
        return isNearForm(
            word, other, foldedWord: fold(word), foldedOther: fold(other), wordValue: NumberWords.value(of: [word]),
            otherValue: NumberWords.value(of: [other]))
    }

    /// `isNearForm` with the folded words and number values given, so a table of cells folds each token once.
    private static func isNearForm(
        _ word: String, _ other: String, foldedWord a: String, foldedOther b: String, wordValue: Int?,
        otherValue: Int?
    ) -> Bool {
        if word == other { return true }
        // Two number words of different value are different numbers ("sześćset" and "sześćdziesiąt").
        if let wordValue, let otherValue, wordValue != otherValue { return false }
        if a == b { return true }
        let shared = zip(a, b).prefix { $0 == $1 }.count
        let shorter = min(a.count, b.count)
        return shared >= 4 && Double(shared) >= 0.6 * Double(shorter)
    }

    private static let negations: Set<String> = ["nie", "not", "no", "bez", "ani", "never", "nigdy"]

    private static func fold(_ word: String) -> String {
        word.folding(options: .diacriticInsensitive, locale: nil).replacingOccurrences(of: "ł", with: "l")
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

    /// Words a speaker adds at the end of a sentence and a cleanup may drop ("no", "prawda", "right").
    private static let trailingParticles: Set<String> = ["no", "nie", "tak", "prawda", "wiesz", "right", "yeah"]
    /// Units that are written as a symbol or an abbreviation ("15%", "200 zł", "$30").
    private static let units: Set<String> = [
        "procent", "procentów", "percent", "złotych", "złote", "złoty", "zł", "dolarów", "dollars", "dollar",
        "euro", "euros", "pln", "usd", "eur",
    ]
    private static let okForms: Set<String> = ["ok", "okay", "okej"]

    /// The output's last word is the input's last word (not counting a trailing filler, marker or discourse
    /// particle), a near form of it, the same unit or "OK" in another spelling, or digits whose value equals the
    /// number words the input ends on (a unit after them may be a symbol). A clock time written in digits
    /// ("7:30") ends where a spoken number ends.
    static func endsWhereInputEnds(spoken: [String], written fullWritten: [String]) -> Bool {
        // A clock time written "15:00" ends in "00", which only says "o'clock" for the hour before it.
        var written = fullWritten
        if written.count >= 2, written.last == "00", NumberWords.value(ofDigits: written[written.count - 2]) != nil {
            written.removeLast()
        }
        guard let lastWritten = written.last else { return false }
        var candidates = [effectiveSpoken(spoken)]
        while let last = candidates[candidates.count - 1].last, candidates[candidates.count - 1].count > 1,
            trailingParticles.contains(last) || units.contains(last)
        {
            candidates.append(Array(candidates[candidates.count - 1].dropLast()))
        }
        let clock = written.count >= 2 && written.suffix(2).allSatisfy { NumberWords.value(ofDigits: $0) != nil }
        return candidates.contains { core in
            guard let lastSpoken = core.last else { return false }
            if isNearForm(lastWritten, lastSpoken) { return true }
            if units.contains(lastWritten), units.contains(lastSpoken) { return true }
            if okForms.contains(lastWritten), okForms.contains(lastSpoken) { return true }
            if clock, NumberWords.value(of: [lastSpoken]) != nil { return true }
            var values: [Int] = []
            if let single = NumberWords.value(ofDigits: lastWritten) { values.append(single) }
            if written.count >= 2, lastWritten.count == 3 {
                for length in 2...min(3, written.count) {
                    let start = written.count - length
                    if let match = NumberWords.digitValues(in: written, at: start).first(where: { $0.tokens == length })
                    {
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
        // Each token is folded and valued once, not once per cell.
        let spokenFolded = spoken.map(fold)
        let writtenFolded = written.map(fold)
        let spokenValues = spoken.map { NumberWords.value(of: [$0]) }
        let writtenValues = written.map { NumberWords.value(of: [$0]) }
        let withdrawn = withdrawnWords.map { ($0, fold($0), NumberWords.value(of: [$0])) }
        let writtenIsNumber = written.indices.map {
            written[$0].contains(where: \.isNumber) || writtenValues[$0] != nil
        }
        let writtenBringsBack = written.indices.map { column -> Bool in
            let word = written[column]
            if word.contains(where: \.isNumber) { return true }
            return withdrawn.contains {
                $0.0 == word
                    || isNearForm(
                        $0.0, word, foldedWord: $0.1, foldedOther: writtenFolded[column], wordValue: $0.2,
                        otherValue: writtenValues[column])
            }
        }
        func near(_ row: Int, _ column: Int) -> Bool {
            isNearForm(
                spoken[row], written[column], foldedWord: spokenFolded[row], foldedOther: writtenFolded[column],
                wordValue: spokenValues[row], otherValue: writtenValues[column])
        }

        var freeEnds = [[Int]](repeating: [], count: rows)
        var lockedMarker = [Bool](repeating: false, count: rows)
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
                spokenValues[index] == nil,
                // A fragment is short; a whole word that starts the next ("pizze pizzerii", "nie niszcz") is not.
                spoken[index].count <= 4, !negations.contains(spoken[index])
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
            let minimum = allowed > 0 ? 1 : 0
            if allowed > 0 { for i in marker.start..<marker.end { lockedMarker[i] = true } }
            for start in stride(from: marker.start - minimum, through: 0, by: -1) where marker.start - start <= allowed
            {
                freeEnds[start].append(marker.end)
            }
        }

        // Two layers: `cost` is the cheapest way when the last step was not a plain deletion, `afterDeletion`
        // when it was. Two plain deletions in a row are never allowed: an unlisted marker in the middle of a
        // chunk ("or rather", "a nie", "znaczy") drops the words it retracts and the final version side by side.
        var cost = [Int](repeating: infinity, count: rows * columns)
        var afterDeletion = [Int](repeating: infinity, count: rows * columns)
        cost[0] = 0
        func relax(_ row: Int, _ column: Int, _ value: Int) {
            let slot = row * columns + column
            if value < cost[slot] { cost[slot] = value }
        }
        func relaxDeletion(_ row: Int, _ column: Int, _ value: Int) {
            let slot = row * columns + column
            if value < afterDeletion[slot] { afterDeletion[slot] = value }
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let kept = cost[row * columns + column]
                let here = min(kept, afterDeletion[row * columns + column])
                if here >= infinity { continue }
                if row < spoken.count {
                    if row < tailStart, !lockedMarker[row], kept < infinity { relaxDeletion(row + 1, column, kept + 1) }
                    for end in freeEnds[row] { relax(end, column, here) }
                }
                guard column < written.count else { continue }
                relax(row, column + 1, here + 1)
                guard row < spoken.count else { continue }
                // "we are" written "we're": two spoken words, one written word, no cost.
                if row + 1 < spoken.count, isContraction(spoken[row], spoken[row + 1], written[column]) {
                    relax(row + 2, column + 1, here)
                }
                if spoken[row] == written[column] {
                    relax(row + 1, column + 1, here)
                } else if (row < tailStart && (!lockedMarker[row] || near(row, column)))
                    || (row >= tailStart && !writtenBringsBack[column]
                        && (near(row, column)
                            || (!spokenWords.contains(written[column]) && spokenValues[row] == nil
                                && (written[column].contains("'")
                                    || closeSpelling(spokenFolded[row], writtenFolded[column]))
                                && !spoken[row].contains(where: \.isNumber) && !writtenIsNumber[column])))
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
        return min(cost[rows * columns - 1], afterDeletion[rows * columns - 1])
    }

    /// The output dropped the first marker that has words after it but kept the last withdrawn word before it
    /// (connectors such as "albo", "a nie" skipped, words the replacement repeats skipped): both versions stay
    /// and nothing tells the reader which one is final ("na pizzę albo na sushi", "we wtorek, a nie w środę").
    private static let connectors: Set<String> = ["nie", "albo", "a", "lub", "czy", "i", "to", "or", "no", "oh", "and"]
    static func markerDroppedWithWithdrawnKept(spoken: [String], written: [String]) -> Bool {
        guard let start = replacementStart(spoken),
            let marker = occurrences(of: retractionMarkers, in: spoken).first(where: { $0.end == start })
        else { return false }
        let phrase = Array(spoken[marker.start..<marker.end])
        let markerKept = written.indices.contains {
            written.count - $0 >= phrase.count && Array(written[$0..<($0 + phrase.count)]) == phrase
        }
        if markerKept { return false }
        let tail = Array(spoken[start...])
        var index = marker.start - 1
        while index >= 0, connectors.contains(spoken[index]) || !fillerLengths(spoken, at: index).isEmpty { index -= 1 }
        guard index >= 0 else { return false }
        let word = spoken[index]
        let value = NumberWords.value(of: [word])
        // The word may also be one the replacement says ("czerwoną sofę albo szarą sofę"): the output then holds
        // it once for the replacement, and a second time means the withdrawn version stayed too.
        let inReplacement = tail.filter {
            isNearForm($0, word) || (value != nil && NumberWords.value(of: [$0]) == value)
        }
        let inOutput = written.filter {
            isNearForm($0, word) || (value != nil && NumberWords.value(ofDigits: $0) == value)
        }
        return inOutput.count > inReplacement.count
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

    /// A recognition fix: at most a third of the longer word's letters differ (edit distance), at least one.
    static func closeSpelling(_ a: String, _ b: String) -> Bool {
        let x = Array(a)
        let y = Array(b)
        var previous = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var current = [i] + [Int](repeating: 0, count: y.count)
            for j in stride(from: 1, through: y.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count] <= max(1, max(x.count, y.count) / 3)
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

    /// "przepraszam" is both an answer opening and a retraction marker: the check below is skipped when the
    /// input contains the opening itself.
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
