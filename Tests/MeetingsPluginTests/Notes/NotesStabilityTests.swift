import Foundation
import Testing

@testable import MeetingsPlugin

/// Run-to-run stability on ONE synthetic meeting (invented, English, 24 areas, 3 speakers) and a scripted model
/// whose behaviour differs from run to run the way a small model's does: it misses a few points in MAP, and
/// in some runs its REDUCE answer is cut off by the token limit (it loops; greedy decoding repeats the loop
/// for the same prompt) or comes back as noise. The runs are fixed by their number, so the table is the same on
/// every machine. This measures how the PIPELINE reacts to such a model (status, what stands in each section),
/// not the quality of any real model.
///
/// It asserts nothing but that every run finishes. `LINTEL_NOTES_STABILITY_OUT=<file>` writes the table
/// (numbers only); `LINTEL_NOTES_STABILITY_RUNS` sets the number of runs (default 20). The same file runs on an
/// older checkout for the "before" column.
@Suite struct NotesStabilityTests {
    enum ReduceMode: String { case ok, loops, noise }

    struct Row {
        var run: Int
        var mode: ReduceMode
        var status: String
        var decisions = 0
        var tasks = 0
        var topics = 0
        var questions = 0
        /// How many thirds of the meeting the topics come from (0...3).
        var thirds = 0
        var hasSummary = false
        var requests = 0
    }

    // MARK: Synthetic meeting

    static let speakers = ["Anna", "Marek", "Ewa"]

    /// 24 areas, each with a topic line; the other kinds are placed between them.
    static func transcript() -> [NotesUtterance] {
        var lines: [(speaker: String, text: String)] = []
        let areaWords = [
            "billing", "search", "mobile", "exports", "alerts", "onboarding", "reports", "payments", "caching",
            "logging", "security", "backups", "pricing", "support", "hiring", "legal", "analytics", "design",
            "release", "training", "partners", "vendors", "budget", "roadmap",
        ]
        for (index, word) in areaWords.enumerated() {
            let number = index + 1
            let speaker = speakers[index % 3]
            lines.append((speaker, "The \(word) area number \(number) is on track for the quarter."))
            switch number {
            case 3:
                lines.append(("Marek", "Marek, please send the offer to the client by Friday."))
            case 5:
                lines.append(("Anna", "Marek will send the offer to the client by Friday."))
            case 6:
                lines.append(("Ewa", "Ewa, bring coffee for everyone on Monday morning."))
            case 7:
                lines.append(("Anna", "When will it be ready?"))
            case 9:
                lines.append(("Marek", "The export job fails on large files."))
            case 10:
                lines.append(("Anna", "The export job fails because the temp folder is full."))
            case 11:
                lines.append(("Ewa", "So we go with plan B for the rollout."))
            case 12:
                lines.append(("Anna", "Anna, write the rollout checklist by Wednesday."))
            case 13:
                lines.append(("Marek", "Who will handle the contract with the supplier?"))
            case 15:
                lines.append(("Ewa", "See you next week and enjoy the weekend."))
            case 16:
                lines.append(("Anna", "Is that okay?"))
            case 18:
                lines.append(("Marek", "Let us drop the old dashboard and keep only the new one."))
            case 20:
                lines.append(("Ewa", "Ewa will book the training room for the second week."))
            case 22:
                lines.append(("Anna", "Who owns the budget review in the next quarter?"))
            case 23:
                lines.append(("Marek", "Agreed, we freeze the budget until the audit is done."))
            default: break
            }
        }
        return lines.enumerated().map { index, line in
            NotesUtterance(startMs: index * 60_000, speaker: line.speaker, text: line.text)
        }
    }

    /// The point the scripted model reports for a line, if any.
    static func point(for text: String) -> (kind: String, text: String, person: String, due: String)? {
        let quote = text.trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
        if text.hasPrefix("The ") && text.contains(" area number ") { return ("SUM", quote + ".", "-", "-") }
        if text.hasPrefix("The export job") { return ("SUM", quote + ".", "-", "-") }
        if text.hasSuffix("?") { return ("ASK", quote + "?", "-", "-") }
        if text.contains("go with plan B") || text.contains("drop the old dashboard")
            || text.contains("freeze the budget")
        {
            return ("DEC", quote + ".", "-", "-")
        }
        if text.hasPrefix("Marek, please send") { return ("TASK", "Send the offer to the client.", "Marek", "Friday") }
        if text.hasPrefix("Marek will send") { return ("TASK", "Send the offer to the client.", "Marek", "Friday") }
        if text.hasPrefix("Ewa, bring coffee") { return ("TASK", "Bring coffee for everyone.", "Ewa", "Monday") }
        if text.hasPrefix("See you next week") { return ("TASK", "See you next week.", "-", "-") }
        if text.hasPrefix("Anna, write") { return ("TASK", "Write the rollout checklist.", "Anna", "Wednesday") }
        if text.hasPrefix("Ewa will book") { return ("TASK", "Book the training room.", "Ewa", "-") }
        return nil
    }

    // MARK: The scripted model

    static func mode(of run: Int) -> ReduceMode {
        switch run % 5 {
        case 2, 4: .loops
        case 3: run % 10 == 3 ? .noise : .ok
        default: .ok
        }
    }

    /// Whether the model misses the point of line `index` in this run (about one in eight).
    static func misses(run: Int, line: Int) -> Bool { (run * 31 + line * 17) % 8 == 0 }

    static func handler(run: Int) -> ScriptedLLM.Handler {
        let mode = mode(of: run)
        return { _, messages, _ in
            if NotesFake.isMap(messages) {
                var out: [String] = []
                for line in NotesFake.transcriptLines(messages) {
                    guard let found = point(for: line.text) else { continue }
                    let quote = line.text.trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
                    out.append(
                        "\(found.kind) | \(line.time) | \"\(quote)\" | \(found.text)"
                            + (found.kind == "TASK" ? " | \(found.person) | \(found.due)" : ""))
                }
                return .done(out.isEmpty ? "NONE" : out.joined(separator: "\n"))
            }
            if NotesFake.isReduce(messages) {
                let reminded = NotesFake.lastUser(messages).contains(NotesPrompt.formatReminder)
                switch mode {
                case .ok: return .done(NotesFake.reduceAnswer(messages, summary: "The areas are on track."))
                case .loops:
                    // Greedy decoding repeats its loop for the same prompt; a changed prompt breaks it.
                    if reminded { return .done(NotesFake.reduceAnswer(messages, summary: "The areas are on track.")) }
                    return .cutOff("SUMMARY: The areas are on track.\nDECISIONS: p1, p1, p1, p1, p1, p1, p1, p1, p1")
                case .noise: return .done("I cannot help with that.")
                }
            }
            return .done("SUMMARY: The areas are on track.")
        }
    }

    // MARK: Measurement

    static func measure(run: Int) async throws -> Row {
        // The model misses some lines in this run by answering without them.
        let missed = Set(
            transcript().enumerated().filter { misses(run: run, line: $0.offset) }.map(\.element.text))
        let inner = handler(run: run)
        let filtered = NotesRig { call, messages, tokens in
            let result = try await inner(call, messages, tokens)
            guard NotesFake.isMap(messages) else { return result }
            let kept = result.text.split(separator: "\n").filter { line in
                !missed.contains {
                    line.contains("\"" + $0.trimmingCharacters(in: CharacterSet(charactersIn: ".?!")) + "\"")
                }
            }
            return .done(kept.isEmpty ? "NONE" : kept.joined(separator: "\n"))
        }
        let result = try await filtered.pipeline().run(utterances: transcript())
        var row = Row(run: run, mode: mode(of: run), status: result.status.rawValue)
        row.requests = filtered.llm.calls.count
        let markdown = result.markdown ?? ""
        row.decisions = bullets(of: "Decisions", in: markdown).count
        row.tasks = bullets(of: "Action items", in: markdown).count
        row.questions = bullets(of: "Open questions", in: markdown).count
        let topics = bullets(of: "Topics discussed", in: markdown)
        row.topics = topics.count
        var thirds = Set<Int>()
        for topic in topics {
            if let match = topic.firstMatch(of: /area number (\d+)/), let number = Int(match.1) {
                thirds.insert((number - 1) / 8)
            }
        }
        row.thirds = thirds.count
        row.hasSummary = markdown.contains("## Summary")
        return row
    }

    static func bullets(of heading: String, in markdown: String) -> [String] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("#") && $0.hasSuffix(heading) }) else { return [] }
        return Array(lines[(start + 1)...].drop { $0.isEmpty }.prefix { $0.hasPrefix("- ") })
    }

    static func table(_ rows: [Row]) -> String {
        var out =
            "run | reduce model | status | decisions | tasks | topics | topic thirds | questions | summary | requests\n"
        out += "--- | --- | --- | --- | --- | --- | --- | --- | --- | ---\n"
        for r in rows {
            out +=
                "\(r.run) | \(r.mode.rawValue) | \(r.status) | \(r.decisions) | \(r.tasks) | \(r.topics) | \(r.thirds) | \(r.questions) | \(r.hasSummary ? 1 : 0) | \(r.requests)\n"
        }
        let partial = rows.filter { $0.status == "partial" }.count
        func range(_ key: KeyPath<Row, Int>) -> String {
            let values = rows.map { $0[keyPath: key] }
            return "\(values.min() ?? 0)-\(values.max() ?? 0)"
        }
        out += "\nruns: \(rows.count), partial: \(partial), ok: \(rows.filter { $0.status == "ok" }.count)\n"
        out +=
            "ranges: decisions \(range(\.decisions)), tasks \(range(\.tasks)), topics \(range(\.topics)), thirds \(range(\.thirds)), questions \(range(\.questions))\n"
        return out
    }

    @Test func theRunsFinishAndTheTableIsWritten() async throws {
        let environment = ProcessInfo.processInfo.environment
        let count = environment["LINTEL_NOTES_STABILITY_RUNS"].flatMap(Int.init) ?? 20
        var rows: [Row] = []
        for run in 1...count { rows.append(try await Self.measure(run: run)) }
        #expect(rows.count == count)
        if let path = environment["LINTEL_NOTES_STABILITY_OUT"] {
            try Self.table(rows).write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
