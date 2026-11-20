import Foundation

/// Checks what the formatting model returned and throws away what is not a cleaned version of the input
/// (spec: `FormatterGuard`). A rejected chunk is replaced by the raw text, so a bad answer never reaches the
/// user's document.
///
/// Best effort, not a guarantee (ADR 0010): the checks are the length range, the language and one rule for
/// negation. The guard does not compare the words of the answer with the words that were spoken.
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
        /// The chunk holds a spoken retraction marker and a negation stands before the first one ("nie przyjdę
        /// jutro czekaj przyjdę jutro"): a cleanup can drop the negation together with the withdrawn words and
        /// turn the sentence round, and the guard cannot tell. The raw text is pasted.
        case negationBeforeMarker
    }

    /// The output may hold 0.6 to 1.15 times the input's words.
    static let lengthRange = 0.6...1.15

    static func check(input: String, output rawOutput: String) -> Verdict {
        let output = clean(rawOutput)
        guard !output.isEmpty else { return .rejected(.empty) }

        if answersInsteadOfCleaning(input: input, output: output) { return .rejected(.answered) }

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
        if negationBeforeMarker(in: input) { return .rejected(.negationBeforeMarker) }
        return .accepted(output)
    }

    /// The spoken markers with which a speaker withdraws a fragment (the list of the cleanup prompt), as
    /// lower-cased words.
    static let retractionMarkers: [[String]] = [
        ["czekaj"], ["jednak"], ["właściwie"], ["pomyłka"], ["przepraszam"], ["to", "znaczy"],
        ["wait"], ["actually"], ["sorry"], ["scratch", "that"], ["i", "mean"],
    ]

    /// Words that negate (Polish, English). A contraction ends in `n't`, or is one of `contractions` when the
    /// recogniser left the apostrophe out; "want" or "moment" is not one.
    static let negations: Set<String> = [
        "nie", "nigdy", "nic", "nikt", "żaden", "żadna", "żadne", "bez", "ani",
        "not", "no", "never", "none", "nothing", "nobody", "neither", "nor", "without", "cannot",
    ]
    static let contractions: Set<String> = [
        "dont", "doesnt", "didnt", "cant", "couldnt", "wont", "wouldnt", "shouldnt", "isnt", "arent", "wasnt",
        "werent", "hasnt", "havent", "hadnt", "mustnt", "neednt", "shant", "aint",
    ]

    static func negates(_ token: String) -> Bool {
        negations.contains(token) || contractions.contains(token) || token.hasSuffix("n't")
    }

    /// Whether the input holds a retraction marker with a negation anywhere before the first one.
    static func negationBeforeMarker(in input: String) -> Bool {
        let tokens = tokens(input)
        guard
            let marker = tokens.indices.first(where: { index in
                retractionMarkers.contains {
                    index + $0.count <= tokens.count && Array(tokens[index..<(index + $0.count)]) == $0
                }
            })
        else { return false }
        return tokens[..<marker].contains(where: negates)
    }

    /// Lower-cased words, split on anything that is not a letter, digit or apostrophe.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
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
