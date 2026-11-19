import Foundation
import Testing

@testable import MeetingsPlugin

/// A synthetic meeting (a school fair, four people, invented), written as the speech recognizer delivers it
/// (sentences cut every few seconds, acknowledgements, a line of Cyrillic on silence, talk about the microphone)
/// and a scripted model that answers the way a small model does: findings that are fragments, a question as a
/// finding, texts that drift from their quotes, a decision that needs two lines. The notes of this meeting
/// before and after the P0 changes are in the pull request (`LINTEL_DUMP_NOTES=<file>` writes them).
@Suite struct NotesSyntheticMeetingTests {
    typealias Segment = (id: Int64, speaker: Int64, start: Int, end: Int, text: String)

    static let speakers: [MeetingDocument.Speaker] = [
        .init(id: 1, label: "Marta", isSelf: false, channel: .system),
        .init(id: 2, label: "Paweł", isSelf: false, channel: .system),
        .init(id: 3, label: "Iza", isSelf: false, channel: .system),
        .init(id: 4, label: "Tomek", isSelf: false, channel: .system),
        .init(id: 5, label: "Mówca 1", isSelf: false, channel: .system),
    ]

    static let segments: [Segment] = [
        (1, 1, 0, 3_000, "No to zaczynamy, dzień dobry wszystkim."),
        (2, 1, 5_000, 9_000, "Mamy dzisiaj do ustalenia budżet festynu i podział prac."),
        (3, 2, 12_000, 13_000, "Mm-hmm."),
        (4, 1, 14_000, 20_000, "Zeszłoroczny festyn kosztował dziewięć tysięcy pięćset złotych."),
        (5, 3, 22_000, 25_000, "A ile mamy w tym roku od sponsora?"),
        (6, 1, 27_000, 32_000, "Sponsor daje trzy tysiące złotych, ale dopiero"),
        (7, 1, 33_000, 37_000, "po otrzymaniu plakatu ze swoim logo."),
        (8, 2, 38_000, 39_000, "Okej."),
        (9, 4, 40_000, 45_000, "Słyszycie mnie? Coś mi się zacina mikrofon."),
        (10, 1, 46_000, 49_000, "Tak, słyszymy. Dobra, dmuchańce."),
        (11, 3, 50_000, 56_000, "Dwa czy trzy? Trzeci nie zmieści się na boisku razem ze sceną."),
        (12, 2, 57_000, 60_000, "No to bierzemy dwa zamiast trzech."),
        (13, 1, 61_000, 67_000, "No dobra, niech tak będzie, osiem tysięcy to nasz budżet."),
        (14, 4, 68_000, 69_000, "Спасибо."),
        (15, 3, 70_000, 73_000, "Co z loterią fantową?"),
        (16, 2, 74_000, 81_000, "Sanepid wymagałby osobnego zgłoszenia na ciasta, więc zamiast ciast robimy loterię."),
        (17, 1, 82_000, 83_000, "Zgoda."),
        (18, 1, 84_000, 91_000, "Paweł, zbierz fanty od rodziców klas jeden do trzech do końca maja."),
        (19, 2, 92_000, 94_000, "Jasne, zrobię to."),
        (20, 1, 95_000, 102_000, "Iza, a ty przygotuj plakat i wyślij go dyrekcji do akceptacji."),
        (21, 3, 103_000, 105_000, "Dobrze, zajmę się tym."),
        (22, 4, 108_000, 109_000, "Thank you."),
        (23, 4, 110_000, 117_000, "Zapytam w urzędzie, czy gmina zgodzi się zamknąć ulicę przed szkołą."),
        (24, 1, 118_000, 122_000, "Odpowiedź potrzebna przed drukiem plakatu."),
        (25, 3, 124_000, 129_000, "A kto weźmie dyżury przy stoiskach w dniu festynu?"),
        (26, 1, 130_000, 134_000, "Tego jeszcze nie ustaliliśmy."),
        (27, 5, 135_000, 139_000, "Ja mogę pomóc przy nagłośnieniu."),
    ]

    static func document() -> MeetingDocument {
        MeetingDocument(
            id: 1, uuid: "u", startedAt: Date(timeIntervalSince1970: 0), durationMs: 140_000, title: nil,
            status: .ready, speakerMode: .diarized, audioState: .deleted, notesMarkdown: nil, notesStatus: .none,
            notesDroppedCount: 0, speakers: speakers,
            segments: segments.map {
                .init(
                    id: $0.id, channel: .system, startMs: $0.start, endMs: $0.end, speakerID: $0.speaker, text: $0.text)
            })
    }

    /// What a small model answers for this meeting (the same in every version of the guard).
    static let mapAnswer = """
        SUM | 00:05 | "Mamy dzisiaj do ustalenia budżet festynu i podział prac" | Mamy do ustalenia budżet festynu i podział prac.
        SUM | 00:14 | "Zeszłoroczny festyn kosztował dziewięć tysięcy pięćset złotych" | Zeszłoroczny festyn kosztował dziewięć tysięcy pięćset złotych.
        SUM | 00:22 | "A ile mamy w tym roku od sponsora" | Ile pieniędzy jest od sponsora?
        SUM | 00:27 | "Sponsor daje trzy tysiące złotych, ale dopiero po otrzymaniu plakatu ze swoim logo" | Sponsor daje trzy tysiące złotych po otrzymaniu plakatu.
        SUM | 00:40 | "Coś mi się zacina mikrofon" | Ktoś ma problem z mikrofonem.
        SUM | 00:50 | "Trzeci nie zmieści się na boisku razem ze sceną" | Trzeci dmuchaniec nie zmieści się na boisku ze sceną.
        DEC | 00:57 | "No to bierzemy dwa zamiast trzech" | Bierzemy dwa dmuchańce zamiast trzech.
        DEC | 01:01 | "niech tak będzie, osiem tysięcy to nasz budżet" | Budżet festynu to osiem tysięcy złotych.
        DEC | 01:14 | "zamiast ciast robimy loterię" | Loteria fantowa zastępuje ciasta, bo sanepid wymagałby osobnego zgłoszenia.
        TASK | 01:24 | "Paweł, zbierz fanty od rodziców klas jeden do trzech do końca maja" | Zbierać fanty od rodziców klas jeden do trzech. | Paweł | końca maja
        TASK | 01:35 | "Iza, a ty przygotuj plakat i wyślij go dyrekcji do akceptacji" | Przygotować plakat i wysłać go dyrekcji. | Iza | -
        TASK | 01:50 | "Zapytam w urzędzie, czy gmina zgodzi się zamknąć ulicę przed szkołą" | Zapytać w urzędzie o zamknięcie ulicy. | - | -
        SUM | 01:58 | "Odpowiedź potrzebna przed drukiem plakatu" | Odpowiedź z urzędu jest potrzebna przed drukiem plakatu.
        ASK | 02:04 | "A kto weźmie dyżury przy stoiskach w dniu festynu" | Kto weźmie dyżury przy stoiskach w dniu festynu?
        SUM | 02:15 | "Ja mogę pomóc przy nagłośnieniu" | Pomoc przy nagłośnieniu.
        """

    /// REDUCE the way a small model does it: every point of a kind in its section, a paragraph that is mostly
    /// right. The FINDINGS line exists only from prompt version 5.
    static let handler: ScriptedLLM.Handler = { _, messages, _ in
        if NotesFake.isMap(messages) { return .done(mapAnswer) }
        guard NotesFake.isReduce(messages) else { return .done(NotesFake.answer(messages)) }
        return .done(
            NotesFake.reduceAnswer(
                messages,
                summary: "Mamy budżet festynu i podział prac. Budżet to osiem tysięcy."
            ))
    }

    private func notes() async throws -> (markdown: String, utterances: [NotesUtterance]) {
        let utterances = NotesUtterance.make(from: Self.document())
        let rig = NotesRig(Self.handler)
        let result = try await rig.pipeline().run(utterances: utterances)
        let markdown = try #require(result.markdown)
        if let path = ProcessInfo.processInfo.environment["LINTEL_DUMP_NOTES"] {
            try markdown.write(toFile: path, atomically: true, encoding: .utf8)
            try utterances.map(\.line).joined(separator: "\n").write(
                toFile: path + ".transcript", atomically: true, encoding: .utf8)
        }
        return (markdown, utterances)
    }

    @Test func theTranscriptIsCleanedBeforeTheModelSeesIt() throws {
        let utterances = NotesUtterance.make(from: Self.document())
        // 27 segments: the acknowledgements, the Cyrillic line and "Thank you." are gone, the cut sentence is one.
        #expect(utterances.count < Self.segments.count - 4)
        let text = utterances.map(\.text).joined(separator: "\n")
        for gone in ["Mm-hmm", "Okej.", "Спасибо", "Thank you"] { #expect(!text.contains(gone), "\(gone)") }
        #expect(text.contains("Sponsor daje trzy tysiące złotych, ale dopiero po otrzymaniu plakatu ze swoim logo."))
    }

    @Test func theNotesAreASummaryNotAListOfQuotes() async throws {
        let (markdown, _) = try await notes()
        // Sections in the order of the template.
        let headings = ["Podsumowanie", "Decyzje", "Zadania", "Omówione tematy", "Otwarte kwestie", "Uczestnicy"]
        let positions = headings.map { markdown.range(of: "### \($0)")?.lowerBound }
        #expect(!positions.contains { $0 == nil }, "\(markdown)")
        let found = positions.compactMap { $0 }
        #expect(found == found.sorted())

        // Nothing from the microphone talk, the fragments or the bare question stands among the topics.
        #expect(!markdown.contains("mikrofon"))
        #expect(!markdown.contains("Coś mi się zacina"))
        let topics = Self.section("Omówione tematy", in: markdown)
        #expect(!topics.contains { $0.hasSuffix("?") })
        // At most ten topics.
        #expect(topics.count <= NotesGuard.maxKeyPoints)

        // The decisions and tasks are there, with the people the speech names.
        #expect(markdown.contains("Budżet festynu to osiem tysięcy złotych."))
        #expect(markdown.contains("osoba\\: Paweł"))
        #expect(markdown.contains("osoba\\: Iza"))

        // The participants are the people, not the generic label.
        let people = Self.section("Uczestnicy", in: markdown, bullets: false)
        #expect(Set(people.split(separator: ", ").map(String.init)) == ["Marta", "Paweł", "Iza", "Tomek"])
        #expect(!markdown.contains("Mówca 1"))
    }

    @Test func aPointWhoseTextDriftedIsRemovedNotReplacedByTheQuote() async throws {
        let (markdown, _) = try await notes()
        // "Ktoś ma problem z mikrofonem" drifted from its quote; the quote is not shown in its place either.
        #expect(!markdown.contains("Ktoś ma problem"))
        #expect(!markdown.contains("zacina mikrofon"))
        // The summary is the model's paragraph; nothing is composed from quotes.
        #expect(markdown.contains("Mamy budżet festynu i podział prac."))
    }

    private static func section(_ heading: String, in markdown: String, bullets: Bool = false) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(of: "### \(heading)") else { return "" }
        return lines[(start + 1)...].first { !$0.isEmpty } ?? ""
    }

    private static func section(_ heading: String, in markdown: String) -> [String] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(of: "### \(heading)") else { return [] }
        return Array(lines[(start + 1)...].drop { $0.isEmpty }.prefix { $0.hasPrefix("- ") })
    }
}
