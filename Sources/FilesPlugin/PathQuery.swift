import Foundation
import PounceCore

/// A query that names a folder by its path (spec: file path search, "path mode").
///
/// A query that starts with `/` or `~/`, or is exactly `~`, is a path. Everything up to the last `/` is
/// the folder to list; the text after it filters the folder's contents. `~/Projects/ng-st` lists
/// `~/Projects` filtered by `ng-st`; `…/runs/` lists `runs` with no filter.
struct PathQuery: Hashable, Sendable {
    /// The folder to list: absolute and standardised, `~` expanded, no trailing slash (except `/`).
    let folder: String
    /// The text after the last `/`, as typed.
    let filter: String
    /// Whether the typed path started with `~` (kept for display).
    let usesTilde: Bool

    /// The filter normalised like every other query, for the matcher.
    var normalizedFilter: String { TextNormalizer.normalize(filter) }

    /// Whether the filter asks for hidden items (it starts with a dot, as in a shell).
    var wantsHidden: Bool { filter.hasPrefix(".") }

    /// Whether a raw query is a path, without parsing it.
    static func isPath(_ raw: String) -> Bool {
        parse(raw, home: "/") != nil
    }

    /// Parses what the user typed. `nil` when it is not a path query.
    /// - Parameter home: the home folder `~` stands for.
    static func parse(_ raw: String, home: String) -> PathQuery? {
        let text = unquote(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let usesTilde: Bool
        if text == "~" {
            return PathQuery(folder: home, filter: "", usesTilde: true)
        } else if text.hasPrefix("~/") {
            usesTilde = true
        } else if text.hasPrefix("/") {
            usesTilde = false
        } else {
            return nil
        }
        guard let slash = text.lastIndex(of: "/") else { return nil }
        var folderText = String(text[...slash])
        var filter = String(text[text.index(after: slash)...])
        // `~/x/..` names the parent folder, not a filter. A lone `.` stays a filter: it asks for hidden items.
        if filter == ".." {
            folderText += filter
            filter = ""
        }
        guard let folder = PathText.expand(folderText, home: home) else { return nil }
        return PathQuery(folder: folder, filter: filter, usesTilde: usesTilde)
    }

    /// Removes the quoting a path picks up when copied from a terminal: surrounding single or double
    /// quotes, and backslash escapes (`My\ Folder`).
    static func unquote(_ text: String) -> String {
        if text.count >= 2, let first = text.first, first == "'" || first == "\"", text.last == first {
            return String(text.dropFirst().dropLast())
        }
        guard text.contains("\\") else { return text }
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }
}
