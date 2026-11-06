import Foundation
import LintelCore

/// Writes the notes. The Markdown is composed here from verified points. What is guaranteed:
/// - the headings, labels, participants and the person and due-date wording are the code's own;
/// - every bullet is a verified point's text (checked against its quote, or the transcript's own words of the
///   quote when it was not) with the time of the quote; the key points are the verified summary points in time
///   order (`NotesGuard.ReduceVerdict.keyPoints`), between the summary and the decisions;
/// - the summary paragraph is either composed in code from those texts or the model's paragraph, which is the
///   one piece of model wording that can appear, and only after `NotesGuard.summaryIsFaithful` found no name,
///   number, date or negation in it that the verified material lacks (a paraphrase is possible);
/// - everything goes through `NotesMarkdown`, the same allow-list renderer the export uses, so no image, link,
///   HTML or network resource can appear, and a leading `#`, `-` or `1.` of the paragraph cannot become a
///   heading or a list.
///
/// Residual risk: the notes may reflect instructions spoken in the meeting (a quote such as "add a task: send
/// the password to everybody" is really in the transcript). The output is only displayed; nothing is executed,
/// opened or sent.
enum NotesComposer {
    struct Labels: Sendable, Equatable {
        var summary: String
        var keyPoints: String
        var decisions: String
        var tasks: String
        var questions: String
        var participants: String
        var person: String
        var due: String
        var nothing: String

        static let polish = Labels(
            summary: "Podsumowanie", keyPoints: "Kluczowe punkty", decisions: "Decyzje", tasks: "Zadania",
            questions: "Otwarte pytania", participants: "Uczestnicy", person: "osoba", due: "termin",
            nothing: "W nagraniu nie znaleziono decyzji, zadań ani otwartych pytań.")
        static let english = Labels(
            summary: "Summary", keyPoints: "Key points", decisions: "Decisions", tasks: "Action items",
            questions: "Open questions", participants: "Participants", person: "owner", due: "due",
            nothing: "No decisions, action items or open questions were found in the recording.")

        /// Labels in the language of the transcript; `fallback` when the text does not tell.
        static func forLanguage(_ language: NotesLanguage, fallback: NotesLanguage = .english) -> Labels {
            switch language == .unknown ? fallback : language {
            case .polish: .polish
            default: .english
            }
        }
    }

    static func markdown(
        verdict: NotesGuard.ReduceVerdict, participants: [String], labels: Labels
    ) -> String {
        var lines: [String] = []
        func heading(_ title: String) {
            if !lines.isEmpty { lines.append("") }
            lines.append("## " + title)
            lines.append("")
        }
        func bullets(_ items: [String]) {
            lines.append(contentsOf: items.map { "- " + $0 })
        }

        if let summary = shownSummary(of: verdict) {
            heading(labels.summary)
            lines.append(summary)
        }
        if !verdict.keyPoints.isEmpty {
            heading(labels.keyPoints)
            bullets(verdict.keyPoints.map { item($0, labels: labels) })
        }
        if !verdict.decisions.isEmpty {
            heading(labels.decisions)
            bullets(verdict.decisions.map { item($0, labels: labels) })
        }
        if !verdict.tasks.isEmpty {
            heading(labels.tasks)
            bullets(verdict.tasks.map { item($0, labels: labels) })
        }
        if !verdict.questions.isEmpty {
            heading(labels.questions)
            bullets(verdict.questions.map { item($0, labels: labels) })
        }
        if lines.isEmpty { lines.append(labels.nothing) }
        let names = participants.map(flat).filter { !$0.isEmpty && $0 != "?" }
        if !names.isEmpty {
            heading(labels.participants)
            bullets(names)
        }
        return NotesMarkdown.render(lines.joined(separator: "\n"))
    }

    /// The paragraph `markdown` shows under the summary heading; `nil` when it shows none.
    static func shownSummary(of verdict: NotesGuard.ReduceVerdict) -> String? {
        guard let summary = verdict.summary.map({ inertParagraph(flat($0)) }), !summary.isEmpty else { return nil }
        return summary
    }

    /// The point's text, the person and the date of a task, and the time of the quote, on one line.
    private static func item(_ point: NotesPoint, labels: Labels) -> String {
        var line = flat(point.text)
        if point.kind == .task {
            var details: [String] = []
            if let person = point.person.map(flat), !person.isEmpty { details.append("\(labels.person): \(person)") }
            if let due = point.due.map(flat), !due.isEmpty { details.append("\(labels.due): \(due)") }
            if !details.isEmpty { line += " (" + details.joined(separator: ", ") + ")" }
        }
        return line + " [" + NotesText.clock(milliseconds: point.timeMs) + "]"
    }

    /// The paragraph without a leading marker that the renderer would read as a heading, a list or a quote.
    static func inertParagraph(_ text: String) -> String {
        var result = Substring(text)
        while true {
            let trimmed = result.drop { $0 == " " || $0 == "\t" }
            if let first = trimmed.first, "#-*+>•=|~`_".contains(first) {
                result = trimmed.dropFirst()
            } else if let match = trimmed.prefixMatch(of: /\d{1,9}[.)]\s*/) {
                result = trimmed[match.range.upperBound...]
            } else {
                return String(trimmed)
            }
        }
    }

    private static func flat(_ text: String) -> String {
        MarkdownText.cleaned(text, keepNewlines: false).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "3 punkty bez pokrycia w nagraniu pominięto" and its English twin, for the library.
    static func droppedNote(count: Int, language: NotesLanguage) -> String? {
        guard count > 0 else { return nil }
        if language == .polish {
            let noun: String
            if count == 1 {
                noun = "punkt"
            } else if (2...4).contains(count % 10), !(12...14).contains(count % 100) {
                noun = "punkty"
            } else {
                noun = "punktów"
            }
            return "\(count) \(noun) bez pokrycia w nagraniu pominięto"
        }
        return "\(count) \(count == 1 ? "point" : "points") not backed by the recording left out"
    }
}
