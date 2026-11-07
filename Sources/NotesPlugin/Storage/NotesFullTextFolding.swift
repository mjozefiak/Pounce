import Foundation

/// The letters SQLite's `remove_diacritics 2` leaves alone (it folds `ż`, `ó`, `ć` but not `ł`, `đ`, `ø`, which
/// have no decomposition). The index reads its text through the view `note_fts_source`, which folds exactly
/// these; queries are folded the same way here. `TextNormalizer` folds more letters, so it is not used.
enum NotesFullTextFolding {
    static let pairs: [(from: String, to: String)] = [
        ("ł", "l"), ("Ł", "L"), ("đ", "d"), ("Đ", "D"), ("ø", "o"), ("Ø", "O"),
    ]

    static func fold(_ text: String) -> String {
        pairs.reduce(text) { $0.replacingOccurrences(of: $1.from, with: $1.to) }
    }

    /// The FROZEN SQL of migration `v1-notes`: nested `replace()` calls for ł, Ł, đ, Đ, ø, Ø (NULL stays NULL).
    /// Never edit; a new folding needs a new migration that rebuilds the view, the triggers and the index.
    static func frozenSQL(_ expression: String) -> String {
        "replace(replace(replace(replace(replace(replace(\(expression), 'ł', 'l'), 'Ł', 'L'), 'đ', 'd'), 'Đ', 'D'), 'ø', 'o'), 'Ø', 'O')"
    }
}
