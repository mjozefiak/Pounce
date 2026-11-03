import Foundation
import Testing

@testable import MeetingsPlugin

@Suite struct NotesParserTests {
    private func points(_ raw: String) -> [NotesPoint]? {
        if case .points(let points) = NotesParser.parseMap(raw) { points } else { nil }
    }

    @Test func theExamplesOfThePromptParse() {
        for example in NotesPrompt.mapExamples {
            #expect(points(example.output)?.count == example.output.split(separator: "\n").count)
        }
    }

    @Test func aTaskCarriesThePersonAndTheDueDateOnlyWhenGiven() throws {
        let parsed = try #require(
            points(
                """
                TASK | 00:34 | "Marek wyśle ofertę do klienta do piątku" | Wysłać ofertę. | Marek | piątek
                TASK | 10:02 | "I'll look into the login bug" | Look into it. | - | -
                TASK | 11:00 | "Ktoś to zrobi" | Zrobić to.
                """))
        #expect(parsed.map(\.person) == ["Marek", nil, nil])
        #expect(parsed.map(\.due) == ["piątek", nil, nil])
        #expect(parsed[0].timeMs == 34_000)
        #expect(parsed[0].quote == "Marek wyśle ofertę do klienta do piątku")
        #expect(parsed.allSatisfy { $0.id.isEmpty && $0.kind == .task })
    }

    @Test func theKindsAndTheTimesAreRead() throws {
        let parsed = try #require(
            points(
                """
                SUM | 1:02:03 | "a b c" | Fakt.
                dec | 05:09 | "a b c" | Decyzja.
                Q | 5:09 | "a b c" | Pytanie?
                ASK | 05:09 | "a b c" | Pytanie?
                """))
        #expect(parsed.map(\.kind) == [.summary, .decision, .question, .question])
        #expect(parsed[0].timeMs == 3_723_000)
    }

    @Test func aQuoteMayContainBarsAndCurlyQuotes() throws {
        let parsed = try #require(
            points(
                """
                DEC | 00:10 | "wybieramy A | B zamiast C" | Wybrano A lub B.
                DEC | 00:11 | „zostajemy przy planie” | Plan bez zmian.
                DEC | 00:12 | bez cudzysłowu na cytacie | Tekst.
                """))
        #expect(
            parsed.map(\.quote) == ["wybieramy A | B zamiast C", "zostajemy przy planie", "bez cudzysłowu na cytacie"])
        #expect(parsed.map(\.text) == ["Wybrano A lub B.", "Plan bez zmian.", "Tekst."])
    }

    @Test func bulletsFencesAndThinkingAreTolerated() throws {
        let raw = """
            <think>Zastanówmy się, które punkty wybrać...</think>
            ```text
            - DEC | 00:21 | "Zatwierdzamy ten budżet" | Budżet zatwierdzono.
            2. ASK | 00:47 | "kto zajmie się umową" | Kto zajmie się umową?
            ```
            """
        #expect(points(raw)?.map(\.kind) == [.decision, .question])
        // A template that opens the thinking block itself leaves only the closing tag.
        #expect(points("rozważam to\n</think>\nNONE") == [])
        // An unfinished thinking block runs to the end.
        #expect(points("DEC | 00:21 | \"a b c\" | Tekst.\n<think>nie skończyłem") != nil)
    }

    @Test func noneIsAnEmptyAnswerAndProseIsMalformed() {
        #expect(points("NONE") == [])
        #expect(points("none.") == [])
        #expect(points("") == [])
        #expect(NotesParser.parseMap("Oto podsumowanie spotkania: rozmawiano o budżecie.") == .malformed)
        #expect(NotesParser.parseMap("DEC | nie-czas | \"a b c\" | Tekst.") == .malformed)
        #expect(NotesParser.parseMap("DEC | 00:10 | \"a b c\"") == .malformed)
        #expect(NotesParser.parseMap("WTF | 00:10 | \"a b c\" | Tekst.") == .malformed)
    }

    @Test func aBadLineBesideGoodOnesIsIgnored() {
        let parsed = points("Oto lista:\nDEC | 00:10 | \"a b c\" | Tekst.\nkoniec")
        #expect(parsed?.count == 1)
    }

    @Test func longFieldsAreCutOrRefused() throws {
        let text = String(repeating: "słowo ", count: 200)
        let parsed = try #require(points("DEC | 00:10 | \"a b c\" | \(text)"))
        #expect(parsed[0].text.count <= NotesParser.maxTextLength)
        #expect(NotesParser.parseMap("DEC | 00:10 | \"\(text)\" | Tekst.") == .malformed)
    }

    @Test func theReduceStructureIsRead() throws {
        let output = try #require(
            NotesParser.parseReduce(
                """
                SUMMARY: Omówiono budżet.
                Zatwierdzono go bez zmian.
                DECISIONS: p1, p3
                TASKS: p2 p4,
                QUESTIONS: -
                """))
        #expect(output.summary == "Omówiono budżet. Zatwierdzono go bez zmian.")
        #expect(output.decisions == ["p1", "p3"])
        #expect(output.tasks == ["p2", "p4"])
        #expect(output.questions.isEmpty)
    }

    @Test func theReduceParserAcceptsPolishKeysMarkdownThinkingAndForeignIds() throws {
        let output = try #require(
            NotesParser.parseReduce(
                """
                <think>hm</think>
                ```
                **Podsumowanie:** Krótko.
                - Decyzje: P2, p77, zmyślone
                - Zadania: p3
                Pytania: p5
                Uczestnicy: Anna, Marek
                ```
                """))
        #expect(output.summary == "Krótko.")
        #expect(output.decisions == ["p2", "p77"])
        #expect(output.tasks == ["p3"])
        #expect(output.questions == ["p5"])
    }

    @Test func aReduceAnswerWithoutAnyKeyIsMalformed() {
        #expect(NotesParser.parseReduce("Oto struktura notatek: wszystko jest w porządku.") == nil)
        #expect(NotesParser.parseReduce("") == nil)
        #expect(NotesParser.parseSummary("SUMMARY: Jedno zdanie.") == "Jedno zdanie.")
    }
}
