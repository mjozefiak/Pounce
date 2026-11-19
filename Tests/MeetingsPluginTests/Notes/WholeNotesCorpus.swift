import Foundation
import Testing

@testable import MeetingsPlugin

/// The synthetic corpus of the whole-transcript track (`Fixtures/whole-notes/`). Every case is a made-up
/// meeting written for this repository; nothing comes from a real recording, dictation or person.
struct WholeNotesCase: Decodable {
    struct Fake: Decodable {
        var number: String
        var weekday: String
        var name: String
        var person: String
        var generic: String
        var due: String
    }

    struct GoldTask: Decodable {
        var match: [String]
        var person: String?
        var due: String?
    }

    struct Gold: Decodable {
        var decisions: [[String]]
        var tasks: [GoldTask]
        var open: [[String]]
    }

    struct ExtraFault: Decodable {
        var `class`: String
        var append: String
        var absent: [String]?
        var expect: String
        var gap: Bool?
    }

    var synthetic: Bool
    var name: String
    var language: String
    var durationSec: Int
    var fake: Fake
    var transcript: [String]
    var gold: Gold
    var correct: String
    var extraFaults: [ExtraFault]

    var utterances: [NotesUtterance] {
        transcript.compactMap { line in
            guard let match = line.firstMatch(of: /^\[([\d:]+)\]\s+([^:]+):\s+(.+)$/),
                let ms = NotesText.parseClock(String(match.1))
            else { return nil }
            return NotesUtterance(startMs: ms, speaker: String(match.2), text: String(match.3))
        }
    }

    var durationMs: Int { durationSec * 1000 }

    static func all() throws -> [WholeNotesCase] {
        let directory = try #require(Bundle.module.url(forResource: "Fixtures/whole-notes", withExtension: nil))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasSuffix(".json")
        }.sorted()
        return try names.map {
            try JSONDecoder().decode(WholeNotesCase.self, from: Data(contentsOf: directory.appending(path: $0)))
        }
    }
}

/// A planted fault: the correct answer with one change, and what the guard must do about it.
struct WholeNotesFault {
    enum Expect: Equatable {
        case dropped, personReset, dueRemoved, timeOmitted, stripped, cut, unusable, noSummary, passes

        init(name: String) {
            switch name {
            case "stripped": self = .stripped
            case "passes": self = .passes
            default: self = .dropped
            }
        }
    }

    var name: String
    var hard: Bool
    var answer: String
    var expect: Expect
    var absent: [String] = []
    var gap = false

    static func faults(for corpus: WholeNotesCase) -> [WholeNotesFault] {
        let fake = corpus.fake
        let pl = corpus.language == "pl"
        func line(_ polish: String, _ english: String) -> String { pl ? polish : english }
        let answer = corpus.correct
        let firstDecision =
            answer.split(separator: "\n").first { $0.hasPrefix("DECISION") }.map(String.init)
            ?? "DECISION | ~00:10 | x"
        let decisionText =
            firstDecision.split(separator: "|").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "x"
        var list: [WholeNotesFault] = [
            .init(
                name: "number", hard: true,
                answer: answer + "\n"
                    + line(
                        "DECISION | ~00:10 | Budżet wynosi \(fake.number) złotych.",
                        "DECISION | ~00:10 | The budget is \(fake.number) dollars."),
                expect: .dropped, absent: [fake.number]),
            .init(
                name: "numberWords", hard: true,
                answer: answer + "\n"
                    + line(
                        "DECISION | ~00:10 | Budżet wynosi siedem tysięcy czterysta złotych.",
                        "DECISION | ~00:10 | The budget is seven thousand four hundred dollars."),
                expect: .dropped, absent: [line("siedem tysięcy", "seven thousand")]),
            .init(
                name: "weekday", hard: true,
                answer: answer + "\n"
                    + line(
                        "TASK | ~00:10 | - | - | Oddać raport w \(fake.weekday).",
                        "TASK | ~00:10 | - | - | Deliver the report on \(fake.weekday)."),
                expect: .dropped, absent: [fake.weekday]),
            .init(
                name: "name", hard: false,
                answer: answer + "\n"
                    + line(
                        "POINT | Rozmowa z firmą \(fake.name) dotyczyła umowy.",
                        "POINT | The talk with \(fake.name) was about the contract."),
                expect: .dropped, absent: [fake.name]),
            .init(
                name: "person", hard: true,
                answer: answer + "\n"
                    + line(
                        "TASK | ~00:20 | \(fake.person) | - | Przygotować raport.",
                        "TASK | ~00:20 | \(fake.person) | - | Prepare the report."),
                expect: .personReset, absent: [fake.person]),
            .init(
                name: "genericPerson", hard: true,
                answer: answer + "\n"
                    + line(
                        "TASK | ~00:20 | \(fake.generic) | - | Przygotować raport.",
                        "TASK | ~00:20 | \(fake.generic) | - | Prepare the report."),
                expect: .personReset, absent: [fake.generic]),
            .init(
                name: "due", hard: false,
                answer: answer + "\n"
                    + line(
                        "TASK | ~00:20 | - | \(fake.due) | Przygotować raport.",
                        "TASK | ~00:20 | - | \(fake.due) | Prepare the report."),
                expect: .dueRemoved, absent: [fake.due]),
            .init(
                name: "link", hard: true,
                answer: answer + "\nOPEN | " + line("Zobacz", "See")
                    + " [here](https://evil.example/a) ![x](https://evil.example/b.png) <b>now</b> www.evil.example.",
                expect: .stripped, absent: ["evil.example", "<b>", "![", "]("]),
            .init(
                name: "time", hard: false,
                answer: answer + "\nDECISION | ~99:59 | \(decisionText)", expect: .timeOmitted),
            .init(
                name: "limit", hard: false,
                answer: answer
                    + String(
                        repeating: "\n"
                            + line("OPEN | Kolejna kwestia do omówienia.", "OPEN | Another point to discuss."),
                        count: 8),
                expect: .cut),
            .init(
                name: "longLine", hard: false,
                answer: answer + "\nOPEN | " + line("Zespół omówił ten temat", "The team went over this topic") + " "
                    + Array(repeating: line("zespół omówił ten temat", "the team went over this topic"), count: 7)
                    .joined(separator: " ") + ".",
                expect: .cut),
            .init(
                name: "junk", hard: false, answer: "Notes follow.\nHere is the summary of the meeting.",
                expect: .unusable),
            .init(name: "truncated", hard: false, answer: answer + "\nTASK | ~01:1", expect: .unusable),
            .init(
                name: "noSummary", hard: false,
                answer: answer.split(separator: "\n").filter { !$0.hasPrefix("SUMMARY") }.joined(separator: "\n"),
                expect: .noSummary),
        ]
        for extra in corpus.extraFaults {
            list.append(
                .init(
                    name: extra.class, hard: extra.class == "injection", answer: answer + "\n" + extra.append,
                    expect: Expect(name: extra.expect),
                    absent: extra.absent ?? [], gap: extra.gap == true))
        }
        return list
    }
}

/// The rubric of the quality gate: what the notes found of the reference list.
struct WholeNotesRubric: Equatable {
    var decisionsExpected = 0
    var decisionsFound = 0
    var tasksExpected = 0
    var tasksFound = 0
    var tasksWithCorrectPerson = 0
    var openExpected = 0
    var openFound = 0
    /// Decisions, tasks and open points of the notes that match nothing in the reference (read by hand).
    var unmatched: [String] = []
    var words = 0

    private static func matches(_ stems: [String], _ text: String) -> Bool {
        let words = NotesText.words(text)
        return stems.allSatisfy { stem in words.contains { $0.hasPrefix(stem) } }
    }

    static func score(draft: NotesDraft, gold: WholeNotesCase.Gold) -> WholeNotesRubric {
        var rubric = WholeNotesRubric()
        rubric.decisionsExpected = gold.decisions.count
        rubric.tasksExpected = gold.tasks.count
        rubric.openExpected = gold.open.count
        for stems in gold.decisions where draft.decisions.contains(where: { matches(stems, $0.text) }) {
            rubric.decisionsFound += 1
        }
        for item in gold.tasks {
            guard let task = draft.tasks.first(where: { matches(item.match, $0.text) }) else { continue }
            rubric.tasksFound += 1
            if let person = item.person {
                if let found = task.person,
                    NotesText.words(found).contains(where: {
                        NotesText.namesMatch($0, NotesText.words(person).first ?? "")
                    })
                {
                    rubric.tasksWithCorrectPerson += 1
                }
            } else if task.person == nil {
                rubric.tasksWithCorrectPerson += 1
            }
        }
        for stems in gold.open where draft.open.contains(where: { matches(stems, $0) }) { rubric.openFound += 1 }
        for item in draft.decisions where !gold.decisions.contains(where: { matches($0, item.text) }) {
            rubric.unmatched.append("DECISION: " + item.text)
        }
        for task in draft.tasks where !gold.tasks.contains(where: { matches($0.match, task.text) }) {
            rubric.unmatched.append("TASK: " + task.text)
        }
        for text in draft.open where !gold.open.contains(where: { matches($0, text) }) {
            rubric.unmatched.append("OPEN: " + text)
        }
        rubric.words =
            ([draft.summary ?? ""] + draft.decisions.map(\.text) + draft.tasks.map(\.text)
            + draft.open + draft.topics.flatMap(\.points)).reduce(0) { $0 + $1.split(separator: " ").count }
        return rubric
    }
}
