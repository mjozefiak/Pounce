import Foundation
import LintelCore

/// The rules of the Vocabulary form (DICT-1.2, mockup decisions D6 to D8), without a view and without I/O.
///
/// Words are runs of letters and digits, as in `TermReplacer`. Two spoken forms are "the same" when their words
/// match without case and diacritics and the text between the words matches once white space is ignored.
enum VocabularyRules {
    /// A spoken form of this many words or fewer is used; `TermReplacer` ignores a longer one.
    static let maximumAliasWords = TermReplacer.maximumAliasWords
    /// A single-word variant with fewer characters than this asks for a confirmation (criterion 2, D8).
    static let shortAliasLength = 4
    /// From this many terms on the list has a search field (D11.2b).
    static let searchThreshold = 10

    /// What is wrong with the term field.
    enum TermProblem: Equatable {
        case empty
        /// Another entry already has this term (`existing` is how it is written there).
        case duplicate(existing: String)
        /// The term is a spoken variant of another entry.
        case isVariant(of: String)
    }

    /// What is wrong with one spoken variant.
    enum AliasProblem: Equatable {
        case tooLong
        /// The variant has no letter or digit, so it could never match.
        case noWord
        /// The variant already belongs to another term.
        case belongsTo(term: String)
        /// The variant is another term, which it would turn into this one.
        case isTerm(term: String)
    }

    struct Check: Equatable {
        var term: TermProblem?
        /// The first variant that cannot be used and why.
        var alias: (text: String, problem: AliasProblem)?

        var isValid: Bool { term == nil && alias == nil }

        static func == (lhs: Check, rhs: Check) -> Bool {
            lhs.term == rhs.term && lhs.alias?.text == rhs.alias?.text && lhs.alias?.problem == rhs.alias?.problem
        }
    }

    // MARK: Words and keys

    /// The words of `text`, each as it is written.
    static func words(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The comparison form of a term or variant: normalised words with the gaps between them (white space is one
    /// space, other text is kept without its white space).
    static func key(_ text: String) -> String {
        var output = ""
        var word = ""
        var gap = ""
        func flushWord() {
            guard !word.isEmpty else { return }
            if !output.isEmpty {
                let punctuation = gap.filter { !$0.isWhitespace }
                output += punctuation.isEmpty ? " " : "\u{1}" + punctuation + "\u{1}"
            }
            output += TextNormalizer.normalize(word)
            word = ""
            gap = ""
        }
        for character in text {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else {
                flushWord()
                gap.append(character)
            }
        }
        flushWord()
        return output
    }

    /// Collapses runs of white space and trims the ends; what the user typed otherwise stays.
    static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Draft

    /// The variants as they are saved: tidied, empty ones dropped, one per spoken form, and none equal to the
    /// term itself (the replacer takes the term as a variant anyway).
    static func cleanedAliases(_ aliases: [String], term: String) -> [String] {
        let own = key(term)
        var seen: Set<String> = [own]
        var result: [String] = []
        for alias in aliases {
            let text = tidy(alias)
            let aliasKey = key(text)
            guard !text.isEmpty, !seen.contains(aliasKey) || aliasKey.isEmpty else { continue }
            seen.insert(aliasKey)
            result.append(text)
        }
        return result
    }

    /// The variants that are one word of fewer than `shortAliasLength` characters ("zet"), in the order given.
    static func shortAliases(_ aliases: [String]) -> [String] {
        aliases.filter {
            let words = words(in: $0)
            return words.count == 1 && words[0].count < shortAliasLength
        }
    }

    /// Checks a draft against the other entries. `ignoring` is the index of the entry being edited.
    static func check(
        term rawTerm: String, aliases: [String], ignoring index: Int?, in entries: [VocabularyStore.Term]
    ) -> Check {
        var result = Check()
        let term = tidy(rawTerm)
        let termKey = key(term)
        let others = entries.enumerated().filter { $0.offset != index }.map(\.element)
        if term.isEmpty || termKey.isEmpty {
            result.term = .empty
        } else if let same = others.first(where: { key($0.term) == termKey }) {
            result.term = .duplicate(existing: same.term)
        } else if let owner = others.first(where: { $0.aliases.contains { key($0) == termKey } }) {
            result.term = .isVariant(of: owner.term)
        }
        for alias in aliases {
            let aliasKey = key(alias)
            if aliasKey.isEmpty {
                result.alias = (alias, .noWord)
            } else if words(in: alias).count > maximumAliasWords {
                result.alias = (alias, .tooLong)
            } else if let other = others.first(where: { key($0.term) == aliasKey }) {
                result.alias = (alias, .isTerm(term: other.term))
            } else if let owner = others.first(where: { $0.aliases.contains { key($0) == aliasKey } }) {
                result.alias = (alias, .belongsTo(term: owner.term))
            }
            if result.alias != nil { break }
        }
        return result
    }

    // MARK: Search and order

    /// Terms in alphabetical order, ignoring case (D11.3a); equal ones keep their file order.
    static func sortedIndices(of entries: [VocabularyStore.Term]) -> [Int] {
        entries.indices.sorted { lhs, rhs in
            let order = entries[lhs].term.localizedStandardCompare(entries[rhs].term)
            return order == .orderedSame ? lhs < rhs : order == .orderedAscending
        }
    }

    /// Whether the term or one of its variants contains the query (case and diacritics ignored).
    static func matches(_ entry: VocabularyStore.Term, query: String) -> Bool {
        let wanted = TextNormalizer.normalize(tidy(query))
        guard !wanted.isEmpty else { return true }
        return ([entry.term] + entry.aliases).contains { TextNormalizer.normalize($0).contains(wanted) }
    }

    // MARK: Example

    /// "Heard" and "Inserted" for the form (D5): a sentence built from the first usable variant, run through the
    /// real `TermReplacer` with this one entry. `nil` while there is no term or no usable variant.
    static func example(
        term rawTerm: String, aliases: [String], sentence: (_ phrase: String) -> String
    ) -> (heard: String, inserted: String, term: String)? {
        let term = tidy(rawTerm)
        guard !key(term).isEmpty else { return nil }
        let usable = cleanedAliases(aliases, term: term).filter {
            let count = words(in: $0).count
            return count >= 1 && count <= maximumAliasWords
        }
        guard let first = usable.first else { return nil }
        let heard = sentence(first)
        let replacer = TermReplacer(entries: [.init(term: term, aliases: usable)])
        return (heard, replacer.apply(to: heard), term)
    }
}
