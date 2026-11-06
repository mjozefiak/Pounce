import Foundation
import Testing

@testable import MeetingsPlugin

/// The regression corpus of the notes (`Fixtures/notes/`): short Polish, English and mixed meetings, one with
/// spoken instructions to the model and one in which nobody decides anything. Each JSON case carries the
/// transcript, the answer of a model that makes things up (`modelAnswer`, in the model's own MAP format) and
/// what the finished notes must and must not contain. Offline tests feed `modelAnswer` through the real
/// pipeline and guard; `RealNotesTests` (off by default) runs a real model on the same transcripts.
struct NotesCorpusCase: Decodable, Sendable {
    struct Utterance: Decodable, Sendable {
        var startMs: Int
        var speaker: String
        var text: String
    }

    struct Point: Decodable, Sendable {
        var kind: String
        var time: String
        var quote: String
        var text: String
        var person: String?
        var due: String?

        /// `KIND | mm:ss | "quote" | text | person | due`, the line a model would write.
        var line: String {
            var fields = [kind, time, "\"\(quote)\"", text]
            if kind == "TASK" { fields += [person ?? "", due ?? ""] }
            return fields.joined(separator: " | ")
        }
    }

    struct Expectation: Decodable, Sendable {
        /// Text that stands in the finished notes.
        var keep: [String]
        /// Text that must not (made-up names and dates, markup, a decision nobody took).
        var drop: [String]
        /// Points of `modelAnswer` the guard must leave out.
        var minDropped: Int
    }

    var name: String
    var language: String
    var description: String
    var utterances: [Utterance]
    var modelAnswer: [Point]
    var expect: Expectation

    var transcript: [NotesUtterance] {
        utterances.map { NotesUtterance(startMs: $0.startMs, speaker: $0.speaker, text: $0.text) }
    }

    var mapAnswer: String { modelAnswer.map(\.line).joined(separator: "\n") }

    // MARK: Loading

    static func directory() throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/notes", withExtension: nil))
    }

    static func all() throws -> [NotesCorpusCase] {
        let directory = try directory()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasSuffix(".json")
        }.sorted()
        return try names.map {
            try JSONDecoder().decode(NotesCorpusCase.self, from: Data(contentsOf: directory.appending(path: $0)))
        }
    }

    /// A plain transcript: one `[mm:ss] Speaker: text` (or `[h:mm:ss]`) line per utterance.
    static func plainTranscript(at url: URL) throws -> [NotesUtterance] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            guard let match = line.firstMatch(of: /^\[([\d:]+)\]\s+([^:]+):\s+(.+)$/),
                let start = NotesText.parseClock(String(match.1))
            else { return nil }
            return NotesUtterance(startMs: start, speaker: String(match.2), text: String(match.3))
        }
    }

    static func longMeeting() throws -> [NotesUtterance] {
        try plainTranscript(at: directory().appending(path: "long-pl-meeting.txt"))
    }
}

/// The invariants the notes must keep whatever the model said. Shared by the offline corpus tests and
/// `RealNotesTests`. The marker list is deliberately crude: a legitimate link or URL in the notes would fail
/// it, which is fine, because the notes are composed by code and must not contain any.
enum NotesInvariants {
    static let forbiddenMarkup = ["![", "](", "<img", "<a ", "http://", "https://", "www."]

    static func check(_ result: NotesResult, transcript: [NotesUtterance], context: String) {
        let markdown = result.markdown ?? ""
        for marker in forbiddenMarkup {
            #expect(!markdown.lowercased().contains(marker), "\(context): the notes contain \(marker)")
        }
        let guardrail = NotesGuard(utterances: transcript)
        #expect(result.keyPoints.allSatisfy { $0.kind == .summary }, "\(context): a key point that is no summary point")
        for point in result.points + result.keyPoints {
            // Every point stands on a quote that is really in the recording.
            #expect(!point.quote.isEmpty, "\(context): a point without a quote")
            #expect(
                guardrail.verifyPoints([point]).verified.count == 1, "\(context): a quote that is not in the recording")
            if point.kind == .task {
                let named =
                    point.person.map { person in
                        point.quote.lowercased().contains(person.lowercased())
                            || transcript.contains { $0.speaker == person }
                    } ?? true
                #expect(named, "\(context): a task owner nobody named")
            }
        }
    }
}
