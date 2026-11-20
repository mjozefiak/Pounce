import Foundation

/// The notes as the model wrote them in the line format of `WholeNotesPrompt`, before and after the fact guard.
/// Times are data for the guard only; they never reach the notes (owner decision 3).
struct NotesDraft: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var timeMs: Int?
        var text: String
    }

    struct Task: Equatable, Sendable {
        var timeMs: Int?
        var person: String?
        var due: String?
        var text: String
    }

    struct Topic: Equatable, Sendable {
        var name: String?
        var points: [String]
    }

    var title: String?
    var summary: String?
    var decisions: [Item] = []
    var tasks: [Task] = []
    /// Topics in the order of the answer; the points before the first `TOPIC` are in a topic without a name.
    var topics: [Topic] = []
    var open: [String] = []

    var isEmpty: Bool {
        summary == nil && decisions.isEmpty && tasks.isEmpty && open.isEmpty && topics.allSatisfy { $0.points.isEmpty }
    }

    /// The draft in the answer format (for the merge request of a long meeting).
    var lines: String {
        func time(_ ms: Int?) -> String { ms.map { "~" + NotesText.clock(milliseconds: $0) } ?? "~" }
        var out: [String] = []
        if let title { out.append("TITLE: \(title)") }
        if let summary { out.append("SUMMARY: \(summary)") }
        for item in decisions { out.append("DECISION | \(time(item.timeMs)) | \(item.text)") }
        for task in tasks {
            out.append("TASK | \(time(task.timeMs)) | \(task.person ?? "-") | \(task.due ?? "-") | \(task.text)")
        }
        for topic in topics {
            if let name = topic.name { out.append("TOPIC: \(name)") }
            for point in topic.points { out.append("POINT | \(point)") }
        }
        for text in open { out.append("OPEN | \(text)") }
        return out.joined(separator: "\n")
    }
}

/// Reads the answer of the whole-transcript track. Lines of another shape are skipped and counted.
enum NotesDraftParser {
    struct Parsed: Equatable, Sendable {
        var draft = NotesDraft()
        var skippedLines = 0
        /// The last non-empty line has no valid shape: the answer was probably cut off.
        var lastLineMalformed = false

        /// The one rule of a failed attempt: a cut answer, or an answer with neither `SUMMARY` nor an item.
        var isUsable: Bool { !lastLineMalformed && !draft.isEmpty }
    }

    static func parse(_ raw: String) -> Parsed {
        var parsed = Parsed()
        var draft = NotesDraft()
        var current: Int?  // index of the topic that receives POINT lines
        var lastValid = true
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            lastValid = true
            if let value = value(of: line, keyword: "TITLE:") {
                if draft.title == nil, !value.isEmpty {
                    draft.title = value
                } else if value.isEmpty {
                    lastValid = false
                }
            } else if let value = value(of: line, keyword: "SUMMARY:") {
                if draft.summary == nil, !value.isEmpty {
                    draft.summary = value
                } else if value.isEmpty {
                    lastValid = false
                }
            } else if let value = value(of: line, keyword: "TOPIC:") {
                if value.isEmpty {
                    lastValid = false
                } else {
                    draft.topics.append(.init(name: value, points: []))
                    current = draft.topics.count - 1
                }
            } else if let fields = fields(of: line, keyword: "DECISION", count: 3), let text = nonEmpty(fields[2]) {
                draft.decisions.append(.init(timeMs: time(fields[1]), text: text))
            } else if let fields = fields(of: line, keyword: "TASK", count: 5), let text = nonEmpty(fields[4]) {
                draft.tasks.append(
                    .init(timeMs: time(fields[1]), person: nonDash(fields[2]), due: nonDash(fields[3]), text: text))
            } else if let fields = fields(of: line, keyword: "POINT", count: 2), let text = nonEmpty(fields[1]) {
                if current == nil {
                    draft.topics.append(.init(name: nil, points: []))
                    current = draft.topics.count - 1
                }
                if let index = current { draft.topics[index].points.append(text) }
            } else if let fields = fields(of: line, keyword: "OPEN", count: 2), let text = nonEmpty(fields[1]) {
                draft.open.append(text)
            } else {
                parsed.skippedLines += 1
                lastValid = false
            }
        }
        parsed.draft = draft
        parsed.lastLineMalformed = !lastValid
        return parsed
    }

    private static func value(of line: String, keyword: String) -> String? {
        guard line.hasPrefix(keyword) else { return nil }
        return String(line.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
    }

    /// `KEYWORD | a | b | text`: exactly `count` fields, the last one taking the rest of the line.
    private static func fields(of line: String, keyword: String, count: Int) -> [String]? {
        guard line.hasPrefix(keyword) else { return nil }
        let rest = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("|") else { return nil }
        let parts = ("|" + rest.dropFirst()).split(
            separator: "|", maxSplits: count - 1, omittingEmptySubsequences: false)
        // The keyword is field 0, so `count` fields after it need `count` bars.
        let values = parts.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        guard values.count == count - 1 else { return nil }
        return [keyword] + values
    }

    private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    private static func nonDash(_ text: String) -> String? {
        let flat = text.trimmingCharacters(in: .whitespaces)
        return flat.isEmpty || flat == "-" || flat == "—" ? nil : flat
    }

    private static func time(_ text: String) -> Int? {
        NotesText.parseClock(text.trimmingCharacters(in: CharacterSet(charactersIn: "~ ")))
    }
}
