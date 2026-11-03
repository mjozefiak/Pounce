import Foundation

/// Parses what the model returned. Strict about the format (a line that does not fit is ignored, an answer with
/// no usable line is a failure the pipeline retries) and tolerant about the wrapping: reasoning blocks, code
/// fences, bullets, curly quotes. Pure.
enum NotesParser {
    enum MapResult: Equatable, Sendable {
        /// The points of the answer; empty for `NONE`.
        case points([NotesPoint])
        case malformed
    }

    static let maxTextLength = 400
    static let maxQuoteLength = 400

    // MARK: MAP

    static func parseMap(_ raw: String) -> MapResult {
        let cleaned = NotesText.clean(raw)
        var points: [NotesPoint] = []
        var ignored = 0
        for rawLine in cleaned.split(separator: "\n") {
            let line = stripBullet(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let point = parsePoint(line) {
                points.append(point)
            } else if line.uppercased().trimmingCharacters(in: .punctuationCharacters) != "NONE" {
                ignored += 1
            }
        }
        if points.isEmpty, ignored > 0 { return .malformed }
        return .points(points)
    }

    private static func parsePoint(_ line: String) -> NotesPoint? {
        guard let first = line.firstIndex(of: "|") else { return nil }
        let code = line[line.startIndex..<first].trimmingCharacters(in: .whitespaces).uppercased()
        let kind: NotesPointKind
        switch code {
        case "SUM": kind = .summary
        case "DEC": kind = .decision
        case "TASK": kind = .task
        case "ASK", "Q": kind = .question
        default: return nil
        }
        var rest = String(line[line.index(after: first)...]).trimmingCharacters(in: .whitespaces)
        guard let bar = rest.firstIndex(of: "|"), let time = NotesText.parseClock(String(rest[rest.startIndex..<bar]))
        else { return nil }
        rest = String(rest[rest.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
        guard let (quote, tail) = splitQuote(rest) else { return nil }
        let fields = tail.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let text = fields.first, !text.isEmpty, !quote.isEmpty, quote.count <= maxQuoteLength else {
            return nil
        }
        var person: String?
        var due: String?
        if kind == .task {
            person = optional(fields.count > 1 ? fields[1] : nil)
            due = optional(fields.count > 2 ? fields[2] : nil)
        }
        return NotesPoint(
            id: "", kind: kind, timeMs: time, quote: quote, text: NotesText.truncated(text, limit: maxTextLength),
            person: person, due: due, speaker: nil)
    }

    /// The quoted part and what follows the bar after it. A quote in quotation marks may contain bars.
    private static func splitQuote(_ text: String) -> (String, String)? {
        let pairs: [Character: Character] = ["\"": "\"", "\u{201C}": "\u{201D}", "\u{201E}": "\u{201D}", "«": "»"]
        if let open = text.first, let close = pairs[open] {
            let body = text.dropFirst()
            var search = body.startIndex
            while let end = body[search...].firstIndex(of: close) {
                let after = body[body.index(after: end)...].drop { $0 == " " }
                if after.first == "|" {
                    let quote = body[body.startIndex..<end].trimmingCharacters(in: .whitespaces)
                    return (quote, String(after.dropFirst()).trimmingCharacters(in: .whitespaces))
                }
                search = body.index(after: end)
            }
            return nil
        }
        guard let bar = text.firstIndex(of: "|") else { return nil }
        return (
            text[text.startIndex..<bar].trimmingCharacters(in: .whitespaces),
            String(text[text.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func optional(_ field: String?) -> String? {
        guard let field else { return nil }
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        let none: Set<String> = ["-", "–", "—", "none", "brak", "n/a", "null", "nil", "unknown", "nieznany"]
        return trimmed.isEmpty || none.contains(trimmed.lowercased()) ? nil : trimmed
    }

    // MARK: REDUCE

    static func parseReduce(_ raw: String) -> NotesReduceOutput? {
        let cleaned = NotesText.clean(raw)
        var output = NotesReduceOutput()
        var recognised = false
        var current: Key?
        var summaryLines: [String] = []

        for rawLine in cleaned.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripBullet(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if let (key, value) = keyLine(line) {
                recognised = true
                current = key
                switch key {
                case .summary: summaryLines = value.isEmpty ? [] : [value]
                case .decisions: output.decisions.append(contentsOf: ids(in: value))
                case .tasks: output.tasks.append(contentsOf: ids(in: value))
                case .questions: output.questions.append(contentsOf: ids(in: value))
                case .ignored: break
                }
            } else if current == .summary, !line.isEmpty {
                summaryLines.append(line)
            } else if let current, current != .summary, current != .ignored {
                // A list that continues on the next line.
                switch current {
                case .decisions: output.decisions.append(contentsOf: ids(in: line))
                case .tasks: output.tasks.append(contentsOf: ids(in: line))
                case .questions: output.questions.append(contentsOf: ids(in: line))
                default: break
                }
            }
        }
        guard recognised else { return nil }
        let summary = summaryLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        output.summary = summary.isEmpty || summary == "-" ? nil : summary
        return output
    }

    /// `SUMMARY: …` of the merge of partial summaries.
    static func parseSummary(_ raw: String) -> String? {
        parseReduce(raw)?.summary
    }

    private enum Key { case summary, decisions, tasks, questions, ignored }

    private static let keys: [(names: [String], key: Key)] = [
        (["summary", "podsumowanie"], .summary),
        (["decisions", "decyzje"], .decisions),
        (["tasks", "zadania", "action items"], .tasks),
        (["questions", "open questions", "pytania", "otwarte pytania"], .questions),
        (["participants", "uczestnicy"], .ignored),
    ]

    private static func keyLine(_ line: String) -> (Key, String)? {
        let flat = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(
            in: CharacterSet(charactersIn: "# "))
        guard let colon = flat.firstIndex(of: ":") else { return nil }
        let name = flat[flat.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard let entry = keys.first(where: { $0.names.contains(name) }) else { return nil }
        return (entry.key, String(flat[flat.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func ids(in text: String) -> [String] {
        text.matches(of: /(?i)\bp\d{1,6}\b/).map { String($0.output).lowercased() }
    }

    private static func stripBullet(_ line: String) -> String {
        var text = Substring(line.trimmingCharacters(in: .whitespaces))
        if let match = text.prefixMatch(of: /([-*•]|\d{1,3}[.)])[ ]+/) { text = text[match.range.upperBound...] }
        return String(text)
    }
}
