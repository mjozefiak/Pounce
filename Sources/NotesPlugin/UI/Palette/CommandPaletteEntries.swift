import Foundation
import LintelCore
import LintelKit

/// One line of the command palette (prototype `.pr`): a note to go to or a command to run.
struct PaletteItem: Identifiable, Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case note(NoteItemID)
        /// The index in the command list the palette was built from.
        case command(Int)
    }

    var id: String
    var title: String
    /// The grey text at the end of the line: "3 Nov · meeting" for a note, the shortcut for a command.
    var detail: String
    var target: Target
}

/// What the palette can offer, before the query: the notes (in the explorer's order) and the commands.
struct PaletteCandidate: Equatable, Sendable {
    var title: String
    var detail: String
}

/// The palette's list, pure (spec step 7.1, ⌘P): notes first, then commands. A query keeps what holds every word
/// of it (case, accents and `ł` ignored, like the launcher); a title that starts with the query comes first. With
/// no query the newest notes and every command are listed.
enum CommandPaletteEntries {
    static let emptyQueryNotes = 5
    static let noteLimit = 8

    static func build(
        notes: [(id: NoteItemID, candidate: PaletteCandidate)], commands: [PaletteCandidate], query: String
    ) -> [PaletteItem] {
        let words = TextNormalizer.normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let noteItems = notes.map {
            PaletteItem(
                id: "note:\($0.id.key.rawValue)\(identitySuffix($0.id))", title: $0.candidate.title,
                detail: $0.candidate.detail, target: .note($0.id))
        }
        let commandItems = commands.enumerated().map {
            PaletteItem(
                id: "command:\($0.offset)", title: $0.element.title, detail: $0.element.detail,
                target: .command($0.offset))
        }
        guard !words.isEmpty else {
            return Array(noteItems.prefix(emptyQueryNotes)) + commandItems
        }
        return Array(filter(noteItems, words: words).prefix(noteLimit)) + filter(commandItems, words: words)
    }

    private static func identitySuffix(_ id: NoteItemID) -> String {
        switch id {
        case .live: ""
        case .detached(_, let started): "@\(started)"
        }
    }

    private static func filter(_ items: [PaletteItem], words: [String]) -> [PaletteItem] {
        let matches = items.compactMap { item -> (PaletteItem, Bool)? in
            let title = TextNormalizer.normalize(item.title)
            guard words.allSatisfy({ title.contains($0) }) else { return nil }
            return (item, title.hasPrefix(words[0]))
        }
        return matches.filter(\.1).map(\.0) + matches.filter { !$0.1 }.map(\.0)
    }
}

extension NoteRowPresentation {
    /// The grey text of a note in the palette (prototype: "3 Nov · meeting"): the day, then what the note is.
    func paletteDetail(_ summary: NoteSummary, now: Date) -> String {
        let day = summary.startedAt.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .day().month(.abbreviated))
        let kind: String
        switch summary.kind {
        case .meeting: kind = String(localized: "meeting", comment: "Command palette: a note that is a meeting")
        case .dictation: kind = String(localized: "dictation", comment: "Command palette: a note that is a dictation")
        default: kind = String(localized: "note", comment: "Command palette: a note you wrote")
        }
        return "\(day) · \(kind)"
    }
}
