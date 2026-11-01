import PounceKit

/// Text prepared once for matching: the normalised scalars, where each one came from in the original
/// text, and the fzf-style boundary bonus of each position.
///
/// Sources build one per searchable title when they index it, so a keystroke only runs the matcher.
public struct NormalizedText: Hashable, Sendable {
    /// The text as the user sees it.
    public let original: String
    /// Lowercased, decomposed, diacritics removed and folded with the manual map (`ł` → `l`).
    public let scalars: [Unicode.Scalar]
    /// For every normalised scalar, the `Character` offset in `original` it came from.
    let originalOffsets: [Int]
    /// For every normalised scalar, the bonus for matching a query character there.
    let bonuses: [Int16]

    public init(_ original: String) {
        self = TextNormalizer.prepare(original)
    }

    init(original: String, scalars: [Unicode.Scalar], originalOffsets: [Int], bonuses: [Int16]) {
        self.original = original
        self.scalars = scalars
        self.originalOffsets = originalOffsets
        self.bonuses = bonuses
    }

    /// The normalised form as a string.
    public var normalized: String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}

/// Normalisation shared by every source: lowercase, canonical decomposition (NFD), combining marks
/// removed, and a manual map for letters that do not decompose (`ł` → `l`, `ß` → `ss`, `æ` → `ae`).
public enum TextNormalizer {
    /// Letters without a canonical decomposition, folded to their ASCII base.
    static let manualFolding: [Unicode.Scalar: String] = [
        "ł": "l", "đ": "d", "ø": "o", "ħ": "h", "ı": "i", "ŀ": "l", "ŧ": "t",
        "ß": "ss", "æ": "ae", "œ": "oe", "þ": "th", "ð": "d",
    ]

    /// The normalised form of a string.
    public static func normalize(_ text: String) -> String {
        prepare(text).normalized
    }

    /// Normalises what the user typed. Leading and trailing whitespace is ignored.
    public static func query(_ raw: String) -> NormalizedQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return NormalizedQuery(raw: raw, normalized: normalize(trimmed))
    }

    /// Normalises a title and records offsets and boundary bonuses for the matcher.
    public static func prepare(_ text: String) -> NormalizedText {
        var scalars: [Unicode.Scalar] = []
        var offsets: [Int] = []
        var classes: [CharacterClass] = []
        scalars.reserveCapacity(text.unicodeScalars.count)

        for (offset, character) in text.enumerated() {
            let originalClass = CharacterClass(character)
            for scalar in fold(character) {
                scalars.append(scalar)
                offsets.append(offset)
                // Expanded letters (`æ` → `ae`) keep the class of the original character, so camel-case
                // detection still sees the original case.
                classes.append(
                    originalClass == .upper || originalClass == .lower ? originalClass : CharacterClass(scalar))
            }
        }

        var bonuses: [Int16] = []
        bonuses.reserveCapacity(classes.count)
        var previous = CharacterClass.whitespace
        for (index, current) in classes.enumerated() {
            // Positions produced by one expanded character (the `e` of `ae`) are never boundaries.
            let continuesCharacter = index > 0 && offsets[index] == offsets[index - 1]
            bonuses.append(continuesCharacter ? 0 : FuzzyScoring.bonus(previous: previous, current: current))
            previous = current
        }
        return NormalizedText(original: text, scalars: scalars, originalOffsets: offsets, bonuses: bonuses)
    }

    /// The normalised scalars of one user-perceived character.
    static func fold(_ character: Character) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        let decomposed = String(character).lowercased().decomposedStringWithCanonicalMapping
        for scalar in decomposed.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                continue
            default:
                break
            }
            if let replacement = manualFolding[scalar] {
                result.append(contentsOf: replacement.unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return result
    }
}

/// Character classes used for fzf's boundary bonuses.
enum CharacterClass: Equatable {
    case whitespace
    case delimiter
    case nonWord
    case lower
    case upper
    case letter
    case number

    init(_ character: Character) {
        if character.isWhitespace {
            self = .whitespace
        } else if let scalar = character.unicodeScalars.first {
            self.init(scalar)
        } else {
            self = .nonWord
        }
    }

    init(_ scalar: Unicode.Scalar) {
        let properties = scalar.properties
        if properties.isWhitespace {
            self = .whitespace
        } else if "/,:;|-_.".unicodeScalars.contains(scalar) {
            self = .delimiter
        } else if properties.numericType != nil {
            self = .number
        } else if properties.isUppercase {
            self = .upper
        } else if properties.isLowercase {
            self = .lower
        } else if properties.isAlphabetic {
            self = .letter
        } else {
            self = .nonWord
        }
    }

    var isWord: Bool {
        switch self {
        case .lower, .upper, .letter, .number: true
        case .whitespace, .delimiter, .nonWord: false
        }
    }
}
