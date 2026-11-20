import Foundation

/// The sentences of the Vocabulary section that are built in code (error messages, the example, spoken labels).
/// Every key is in `Resources/Localizable.xcstrings` in English and Polish (`StringCatalogTests`). Terms and
/// variants are the user's own words: they are shown, never logged.
enum VocabularyText {
    // MARK: Messages next to the fields (D6, D7)

    static func termEmpty() -> String {
        String(
            localized: "Type how the term should be written.",
            comment: "Vocabulary form: error under the term field when it is empty")
    }

    static func termDuplicate(_ existing: String) -> String {
        String(
            localized: "“\(existing)” is already in the vocabulary.",
            comment: "Vocabulary form: error when another entry has the same term; the argument is that term")
    }

    static func termIsVariant(_ term: String, owner: String) -> String {
        String(
            localized: "“\(term)” is already a spoken variant of \(owner).",
            comment: "Vocabulary form: error when the new term is a spoken variant of another entry")
    }

    static func aliasBelongsTo(_ alias: String, term: String) -> String {
        String(
            localized: "“\(alias)” already belongs to \(term). A variant can point to one term only.",
            comment: "Vocabulary form: error when a spoken variant is already used by another term")
    }

    static func aliasIsTerm(_ alias: String, other: String, term: String) -> String {
        String(
            localized: "“\(alias)” is the term \(other). It would turn every \(other) into \(term).",
            comment:
                "Vocabulary form: error when a spoken variant equals another term; arguments are the variant, that term and this term"
        )
    }

    static func aliasTooLong() -> String {
        String(
            localized: "A variant can have at most 8 words.",
            comment: "Vocabulary form: error when a spoken variant has more than 8 words")
    }

    static func aliasNoWord(_ alias: String) -> String {
        String(
            localized: "“\(alias)” has no letter or digit, so it could never match.",
            comment: "Vocabulary form: error when a spoken variant has no word in it")
    }

    static func withoutVariantsHint(_ term: String) -> String {
        String(
            localized: "Without variants only the capitalisation is fixed: “\(term.lowercased())” → \(term).",
            comment:
                "Vocabulary form: hint when a term has no spoken variants; arguments are the lowercase and the written term"
        )
    }

    static func saveFailed() -> String {
        String(
            localized: "The term couldn’t be saved. Check that the disk isn’t full.",
            comment: "Vocabulary form: error when writing the vocabulary file failed")
    }

    // MARK: Short variants (D8)

    /// The user's variant in the quotation marks of the language the app speaks.
    static func quote(_ text: String) -> String {
        Bundle.main.preferredLocalizations.first == "pl" ? "„\(text)”" : "“\(text)”"
    }

    static func shortAliasWarning(_ aliases: [String], term: String) -> String {
        let quoted = aliases.map(quote).joined(separator: ", ")
        return String(
            localized:
                "\(quoted) is a short word. Every \(quoted) you dictate will become \(term), also when you mean the letter.",
            comment:
                "Vocabulary form: warning for a one-word variant under 4 characters; arguments are the quoted variants and the term"
        )
    }

    static func shortAliasConfirmation(_ aliases: [String]) -> String {
        let quoted = aliases.map(quote).joined(separator: ", ")
        return String(
            localized: "Use \(quoted) anyway",
            comment:
                "Vocabulary form: checkbox that confirms a short spoken variant; the argument is the quoted variant")
    }

    // MARK: Example (D5)

    /// The sentence the example is built from: the variant between two fixed words.
    static func exampleSentence(_ phrase: String) -> String {
        String(
            localized: "open \(phrase) now",
            comment: "Vocabulary form: the example sentence around a spoken variant; keep the argument as it is")
    }

    // MARK: Counts

    static func termCount(_ count: Int) -> String {
        String(
            localized: "\(count) terms", comment: "Vocabulary section: number of terms, shown at the right of its title"
        )
    }

    static func searchCount(shown: Int, of total: Int) -> String {
        String(
            localized: "\(shown) of \(total)",
            comment: "Vocabulary section: matches of the search out of all terms, for example 2 of 47")
    }

    static func deleteDetail(variants: Int) -> String {
        if variants == 0 {
            return String(
                localized: "This can’t be undone.",
                comment: "Confirmation sheet detail when a vocabulary term without variants is deleted")
        }
        return String(
            localized: "Its \(variants) spoken variants are removed too. This can’t be undone.",
            comment:
                "Confirmation sheet detail when a vocabulary term is deleted; the number is how many spoken variants go with it"
        )
    }

    // MARK: VoiceOver

    static func rowLabel(term: String, aliases: [String]) -> String {
        if aliases.isEmpty {
            return String(
                localized: "\(term). No spoken variants.",
                comment: "VoiceOver: a vocabulary row without variants; the argument is the term")
        }
        return String(
            localized: "\(term). When I hear: \(aliases.joined(separator: ", ")).",
            comment: "VoiceOver: a vocabulary row; arguments are the term and its spoken variants")
    }

    static func rowPosition(_ position: Int, of total: Int) -> String {
        String(
            localized: "Row \(position) of \(total)",
            comment: "VoiceOver: position of a vocabulary row in the list")
    }

    static func tokenLabel(_ alias: String, position: Int, of total: Int) -> String {
        String(
            localized: "\(alias), variant \(position) of \(total)",
            comment: "VoiceOver: a spoken variant in the form; arguments are the text and its position")
    }

    static func termAdded(total: Int) -> String {
        String(
            localized: "Term added. \(total) terms.",
            comment: "VoiceOver announcement after adding a vocabulary term; the number is how many there are now")
    }

    static func termSaved(_ term: String) -> String {
        String(
            localized: "\(term) saved.",
            comment: "VoiceOver announcement after editing a vocabulary term; the argument is the term")
    }

    static func termDeleted(_ term: String) -> String {
        String(
            localized: "\(term) deleted.",
            comment: "VoiceOver announcement after deleting a vocabulary term; the argument is the term")
    }
}
