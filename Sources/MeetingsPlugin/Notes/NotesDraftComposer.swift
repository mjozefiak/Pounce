import Foundation
import LintelCore

extension NotesComposer.Labels {
    /// The owner of a task nobody named. The only caption the whole-transcript track needs besides the shared ones.
    var unassigned: String { self == .polish ? "Do przypisania" : "Unassigned" }
}

/// Writes the notes from a checked `NotesDraft` (the whole-transcript track). The headings, their order and their
/// wording are `NotesComposer.Labels`, the same as the built-in track; the renderer is `NotesMarkdown.render`, so
/// no link, image or HTML can appear. No times and no marks of who wrote what (owner decisions 3 and 4).
///
/// Order: the title (the highest heading), Summary, Decisions, Action items, Topics discussed (a name is a
/// sub-heading), Open questions, Participants (real names only, composed by the code from the speaker labels).
enum NotesDraftComposer {
    static func markdown(draft: NotesDraft, participants: [String], labels: NotesComposer.Labels) -> String {
        var lines: [String] = []
        func heading(_ level: Int, _ title: String) {
            if !lines.isEmpty { lines.append("") }
            lines.append(String(repeating: "#", count: level) + " " + title)
            lines.append("")
        }
        let sectionLevel = 2
        if let title = draft.title.map(flat), !title.isEmpty {
            lines.append("# " + NotesComposer.inertParagraph(title))
        }
        if let summary = draft.summary.map(flat), !summary.isEmpty {
            heading(sectionLevel, labels.summary)
            lines.append(NotesComposer.inertParagraph(summary))
        }
        if !draft.decisions.isEmpty {
            heading(sectionLevel, labels.decisions)
            lines.append(contentsOf: draft.decisions.map { "- " + item($0.text) })
        }
        if !draft.tasks.isEmpty {
            heading(sectionLevel, labels.tasks)
            lines.append(contentsOf: draft.tasks.map { "- [ ] " + task($0, labels: labels) })
        }
        let topics = draft.topics.filter { !$0.points.isEmpty }
        if !topics.isEmpty {
            heading(sectionLevel, labels.keyPoints)
            for topic in topics {
                if let name = topic.name.map(flat), !name.isEmpty {
                    lines.append("")
                    lines.append("### " + NotesComposer.inertParagraph(name))
                    lines.append("")
                }
                lines.append(contentsOf: topic.points.map { "- " + item($0) })
            }
        }
        if !draft.open.isEmpty {
            heading(sectionLevel, labels.questions)
            lines.append(contentsOf: draft.open.map { "- " + item($0) })
        }
        if lines.isEmpty { lines.append(labels.nothing) }
        let names = participants.map(flat).filter { !$0.isEmpty && !NotesGuard.isGenericLabel($0) }
        if !names.isEmpty {
            heading(sectionLevel, labels.participants)
            lines.append(NotesComposer.inertParagraph(names.joined(separator: ", ")))
        }
        return NotesMarkdown.render(lines.joined(separator: "\n"))
    }

    private static func task(_ task: NotesDraft.Task, labels: NotesComposer.Labels) -> String {
        let owner = task.person.map(flat).flatMap { $0.isEmpty ? nil : $0 } ?? labels.unassigned
        var details = ["\(labels.person): \(owner)"]
        if let due = task.due.map(flat), !due.isEmpty { details.append("\(labels.due): \(due)") }
        return item(task.text) + " — " + details.joined(separator: ", ")
    }

    /// One line: no checklist marker, no time.
    private static func item(_ text: String) -> String {
        var result = Substring(flat(text))
        while let match = result.prefixMatch(of: /\[[ xX]\]\s*/) { result = result[match.range.upperBound...] }
        return String(result)
    }

    /// One line of text without the transcript's times (owner decision 3).
    private static func flat(_ text: String) -> String {
        withoutTimes(MarkdownText.cleaned(text, keepNewlines: false)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A time in the notations of the transcript and of the answer ("[12:34]", "~12:34", and "(12:34)" at the end of
    /// a line) is removed wherever it stands; a clock hour in a sentence ("o 17:00") is a fact and stays.
    static func withoutTimes(_ text: String) -> String {
        text.replacing(/\s*\[~?\d{1,2}(?::\d{2}){1,2}\]/, with: "")
            .replacing(/\s*~\d{1,2}(?::\d{2}){1,2}(?!\d)/, with: "")
            .replacing(/\s*\(\d{1,2}(?::\d{2}){1,2}\)\s*$/, with: "")
    }
}
