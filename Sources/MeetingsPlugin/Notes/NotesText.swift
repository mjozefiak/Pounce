import Foundation
import LintelCore

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
        // Until nothing changes: removing a tag can join the pieces of another one ("<trans<transcript>cript>").
        var previous: String
        repeat {
            previous = result
            while let open = result.range(of: "<think>", options: .caseInsensitive) {
                if let close = result.range(
                    of: "</think>", options: .caseInsensitive, range: open.upperBound..<result.endIndex)
                {
                    result.removeSubrange(open.lowerBound..<close.upperBound)
                } else {
                    result.removeSubrange(open.lowerBound..<result.endIndex)
                }
            }
            if let close = result.range(of: "</think>", options: [.backwards, .caseInsensitive]) {
                result.removeSubrange(result.startIndex..<close.upperBound)
            }
            result = strippingPromptTags(result)
        } while result != previous
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes every `<transcript>`, `<points>`, `<summaries>` and `<think>` tag (opening or closing, any case,
    /// with stray spaces or attributes), repeating until none is left: a tag cannot be rebuilt from the pieces
    /// that are left around a removed one.
    static func strippingPromptTags(_ text: String) -> String {
        var result = text
        while true {
            let next = result.replacing(/(?i)<\s*\/?\s*(?:transcript|points|summaries|think)\b[^<>]*>/, with: "")
            if next == result { return result }
            result = next
        }
    }

    // MARK: Words

    /// One word of a text: normalised, with what its original spelling tells.
    struct WordToken: Equatable, Sendable {
        var word: String
        /// The original spelling starts with a capital letter.
        var capitalised: Bool
        /// First word of the text or after a sentence end, a colon or a semicolon.
        var startsSentence: Bool
        /// A sentence end (`.`, `!`, `?` or `…` followed by a space or the end) lies between this and the
        /// previous word, and which one.
        var sentenceEnd: Character?
        /// Character offsets of the word in the original text.
        var start: Int
        var end: Int
    }

    /// The words of a text, each normalised (lowercase, no diacritics, `ł` → `l`) with its original spelling's
    /// capital, its place in the sentence and its position. Splitting is by letters and digits.
    static func tokens(_ text: String) -> [WordToken] {
        let characters = Array(text)
        var result: [WordToken] = []
        var index = 0
        var starts = true
        var pendingEnd: Character?
        while index < characters.count {
            let character = characters[index]
            if character.isLetter || character.isNumber {
                var end = index
                while end < characters.count, characters[end].isLetter || characters[end].isNumber { end += 1 }
                let raw = String(characters[index..<end])
                let parts = TextNormalizer.normalize(raw).split { !($0.isLetter || $0.isNumber) }
                for (offset, part) in parts.enumerated() {
                    result.append(
                        WordToken(
                            word: String(part), capitalised: raw.first?.isUppercase ?? false,
                            startsSentence: offset == 0 && starts, sentenceEnd: offset == 0 ? pendingEnd : nil,
                            start: index, end: end))
                }
                if !parts.isEmpty {
                    starts = false
                    pendingEnd = nil
                }
                index = end
            } else {
                if ".!?\u{2026}".contains(character),
                    index + 1 == characters.count || characters[index + 1].isWhitespace,
                    !continuesAfterDot(characters, at: index)
                {
                    starts = true
                    pendingEnd = character
                } else if ":;".contains(character) {
                    starts = true
                }
                index += 1
            }
        }
        return result
    }

    private static let abbreviations: Set<String> = [
        "np", "tj", "tzn", "itd", "itp", "godz", "ok", "ul", "ws", "wg", "dr", "mgr", "inz", "prof", "nr", "tys",
        "mln", "mld", "zl", "pt", "etc", "ang", "pl", "sp", "ze", "al", "pn", "wt", "sr", "cz", "sob", "niedz",
    ]

    /// A dot after a number (`5. listopada`) or an abbreviation (`np. jutro`) followed by a lowercase letter
    /// does not end the sentence.
    private static func continuesAfterDot(_ characters: [Character], at index: Int) -> Bool {
        guard characters[index] == "." else { return false }
        var next = index + 1
        while next < characters.count, characters[next].isWhitespace { next += 1 }
        guard next < characters.count, characters[next].isLowercase || characters[next].isNumber else {
            return false
        }
        guard index > 0 else { return false }
        if characters[index - 1].isNumber { return true }
        var start = index
        while start > 0, characters[start - 1].isLetter { start -= 1 }
        let word = TextNormalizer.normalize(String(characters[start..<index]))
        return abbreviations.contains(word)
    }

    /// The normalised letters-and-digits words of a text.
    static func words(_ text: String) -> [String] {
        tokens(text).map(\.word)
    }

    /// The numbers written with digits, a decimal, a time or a date counting as one unit (`3.5`, `12:30`,
    /// `5/11/2026`): `3.5` is never the same as `5.3` or `3` and `5`. A comma decimal is written with a dot.
    static func numberUnits(_ text: String) -> [String] {
        let normalized = TextNormalizer.normalize(text)
        return normalized.matches(of: /\d[\p{L}\p{N}]*(?:[.,:\/\-]\d[\p{L}\p{N}]*)*/).map {
            String($0.output).replacingOccurrences(of: ",", with: ".")
        }
    }

    /// Addresses and file-like names (`evil.example`, `bob@evil.example`, `www.x.pl`), lowercase: they are one
    /// unit, so a model cannot slip one in as ordinary words.
    static func linkUnits(_ text: String) -> [String] {
        text.lowercased().matches(of: /[\p{L}\p{N}_\-]+(?:[.@][\p{L}\p{N}_\-]+)+/).map { String($0.output) }
            .filter { $0.contains(where: \.isLetter) }
    }

    /// Two normalised words are the same word, allowing for a Polish case ending. Strict on purpose, because a
    /// false match lets a changed name, number or date through:
    /// - equal words match; a word with a digit must be equal; a number word (`czterdzieści`, `milion`) must be
    ///   equal;
    /// - weekdays and months match across their forms by a table (`piątek`/`piątku`, never `piątego`);
    /// - any other word matches when both share at least 5 letters and what is left of each is a short, known
    ///   ending (`spotkanie`/`spotkaniu`, `ofertę`/`oferta`): `przed`/`przez`, `milion`/`miliard`,
    ///   `bardzo`/`bardziej`, `kiedy`/`kiedyś` do not.
    static func wordsMatch(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        guard let letter = first.utf8.first, letter == second.utf8.first else { return false }
        let ga = Temporal.group(of: first)
        let gb = Temporal.group(of: second)
        if ga != nil || gb != nil { return ga == gb }
        let a = Array(first)
        let b = Array(second)
        guard a.count >= 5, b.count >= 5 else { return false }
        if a.contains(where: \.isNumber) || b.contains(where: \.isNumber) { return false }
        if isNumberWord(first) || isNumberWord(second) { return false }
        let shared = sharedPrefix(a, b)
        guard shared >= 5 else { return false }
        return caseEndings.contains(String(a[shared...])) && caseEndings.contains(String(b[shared...]))
    }

    /// Names match only when equal (after the fold of case and diacritics) or when they differ by a case ending
    /// (`Marek`/`Marka`/`Markowi`, `Ewa`/`Ewy`, `Anna`/`Annie`). Both at least 3 letters. `Marcin`/`Marcel`,
    /// `Maria`/`Marian`, `Julia`/`Julian` do not match.
    static func namesMatch(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        guard first.count >= 3, second.count >= 3, first.first == second.first else { return false }
        if first.contains(where: \.isNumber) || second.contains(where: \.isNumber) { return false }
        let floor = min(first.count, second.count) == 3 ? 2 : 3
        for (a, b) in [(Array(first), Array(second)), (Array(elided(first)), Array(elided(second)))] {
            let shared = sharedPrefix(a, b)
            guard shared >= floor else { continue }
            if nameEndings.contains(String(a[shared...])) && nameEndings.contains(String(b[shared...])) {
                return true
            }
        }
        return false
    }

    /// `marek` → `mark`: the `e` that drops out in `Marka`, `Markowi`.
    private static func elided(_ name: String) -> String {
        name.hasSuffix("ek") && name.count > 3 ? String(name.dropLast(2)) + "k" : name
    }

    private static func sharedPrefix(_ a: [Character], _ b: [Character]) -> Int {
        var shared = 0
        while shared < min(a.count, b.count), a[shared] == b[shared] { shared += 1 }
        return shared
    }

    /// Endings (normalised, at most three letters) a Polish word may differ by, or an English plural and past.
    private static let caseEndings: Set<String> = [
        "", "a", "e", "i", "y", "u", "o", "ie", "ia", "em", "om", "ow", "ej", "im", "ym", "ami", "ach", "ego", "emu",
        "imi", "ymi", "iem", "es", "ed",
    ]
    private static let nameEndings: Set<String> = ["", "a", "e", "i", "y", "u", "ie", "em", "iem", "owi", "om", "ow"]

    /// Spelled-out numbers (normalised forms). They are compared exactly: `czterdzieści` is not `czterdziestu`.
    static func isNumberWord(_ word: String) -> Bool {
        numberWords.contains(word)
    }

    private static let numberWords: Set<String> = [
        "zero", "dwa", "dwie", "dwoch", "dwoje", "trzy", "trzech", "cztery", "czterech", "piec", "pieciu", "szesc",
        "szesciu", "siedem", "siedmiu", "osiem", "osmiu", "dziewiec", "dziewieciu", "dziesiec", "dziesieciu",
        "jedenascie", "jedenastu", "dwanascie", "dwunastu", "trzynascie", "trzynastu", "czternascie", "czternastu",
        "pietnascie", "pietnastu", "szesnascie", "szesnastu", "siedemnascie", "siedemnastu", "osiemnascie",
        "osiemnastu", "dziewietnascie", "dziewietnastu", "dwadziescia", "dwudziestu", "trzydziesci", "trzydziestu",
        "czterdziesci", "czterdziestu", "piecdziesiat", "piecdziesieciu", "szescdziesiat", "szescdziesieciu",
        "siedemdziesiat", "siedemdziesieciu", "osiemdziesiat", "osiemdziesieciu", "dziewiecdziesiat",
        "dziewiecdziesieciu", "sto", "stu", "dwiescie", "dwustu", "trzysta", "trzystu", "czterysta", "czterystu",
        "piecset", "pieciuset", "szescset", "szesciuset", "siedemset", "siedmiuset", "osiemset", "osmiuset",
        "dziewiecset", "dziewieciuset", "tysiac", "tysiace", "tysiecy", "tysiaca", "milion", "miliony", "milionow",
        "miliona", "miliard", "miliardy", "miliardow", "miliarda", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "half", "dozen", "polowa", "polowe", "pol",
    ]

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

    /// `mm:ss` or `h:mm:ss` to milliseconds. Every field is bounded (a model can write anything), so the
    /// arithmetic cannot overflow.
    static func parseClock(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(
            separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ (1...6).contains($0.count) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        let seconds: Int
        if numbers.count == 3 {
            guard numbers[0] <= 99, numbers[1] <= 99, numbers[2] <= 99 else { return nil }
            seconds = numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        } else {
            guard numbers[0] <= 6000, numbers[1] <= 99 else { return nil }
            seconds = numbers[0] * 60 + numbers[1]
        }
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
