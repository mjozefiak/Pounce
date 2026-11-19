import Foundation
import Testing

@testable import MeetingsPlugin

/// The notes-summary P0: transcript cleaning, the FINDINGS line and the v5 MAP prompt.
@Suite struct NotesTranscriptCleaningTests {
    private func document(_ rows: [(speaker: Int64, start: Int, end: Int, text: String)]) -> MeetingDocument {
        let names: [Int64: String] = [1: "Ala", 2: "Olek"]
        return MeetingDocument(
            id: 1, uuid: "u", startedAt: Date(timeIntervalSince1970: 0), durationMs: 100_000, title: nil,
            status: .ready, speakerMode: .diarized, audioState: .deleted, notesMarkdown: nil, notesStatus: .none,
            notesDroppedCount: 0,
            speakers: names.map { .init(id: $0.key, label: $0.value, isSelf: false, channel: .system) },
            segments: rows.enumerated().map {
                .init(
                    id: Int64($0.offset + 1), channel: .system, startMs: $0.element.start, endMs: $0.element.end,
                    speakerID: $0.element.speaker, text: $0.element.text)
            })
    }

    @Test func neighbouringSegmentsOfOneSpeakerBecomeOneUtterance() {
        let utterances = NotesUtterance.make(
            from: document([
                (1, 0, 3000, "Sponsor daje trzy tysiące, ale dopiero"),
                (1, 3500, 6000, "po otrzymaniu plakatu."),
                (2, 7000, 9000, "Rozumiem to dobrze."),
            ]))
        #expect(
            utterances.map(\.text) == [
                "Sponsor daje trzy tysiące, ale dopiero po otrzymaniu plakatu.", "Rozumiem to dobrze.",
            ])
    }

    @Test func aLongPauseOrAnotherSpeakerKeepsSegmentsApart() {
        let utterances = NotesUtterance.make(
            from: document([
                (1, 0, 3000, "Pierwsza część wypowiedzi."),
                (1, 20_000, 23_000, "Druga część po długiej przerwie."),
            ]))
        #expect(utterances.count == 2)
    }

    @Test func acknowledgementsAreDropped() {
        let utterances = NotesUtterance.make(
            from: document([
                (1, 0, 3000, "Zatwierdzamy budżet na przyszły kwartał."),
                (2, 4000, 5000, "Mm-hmm."),
                (2, 6000, 7000, "Okej."),
                (2, 8000, 9000, "Thank you."),
            ]))
        #expect(utterances.map(\.text) == ["Zatwierdzamy budżet na przyszły kwartał."])
    }

    @Test func aSegmentInAForeignAlphabetIsDropped() {
        let utterances = NotesUtterance.make(
            from: document([
                (1, 0, 3000, "Zatwierdzamy budżet na przyszły kwartał."),
                (2, 5000, 6000, "Спасибо большое за внимание."),
            ]))
        #expect(utterances.count == 1)
        #expect(utterances.allSatisfy { !$0.text.contains("Спасибо") })
    }
}

@Suite struct NotesFindingsParsingTests {
    @Test func theFindingsLineIsReadInItsOrder() {
        let output = NotesParser.parseReduce(
            "SUMMARY: Krótko.\nDECISIONS: p2\nTASKS: p3\nFINDINGS: p5, p1, p4\nQUESTIONS: p6")
        #expect(output?.keyPoints == ["p5", "p1", "p4"])
        #expect(output?.questions == ["p6"])
    }

    @Test func aReduceWithoutFindingsHasNone() {
        let output = NotesParser.parseReduce("SUMMARY: Krótko.\nDECISIONS: p2\nTASKS: -\nQUESTIONS: -")
        #expect(output?.keyPoints.isEmpty == true)
    }

    @Test func polishAliasesAreRecognised() {
        let output = NotesParser.parseReduce("PODSUMOWANIE: Krótko.\nUSTALENIA: p1, p2")
        #expect(output?.keyPoints == ["p1", "p2"])
    }
}

@Suite struct NotesMapPromptV5Tests {
    @Test func theMapPromptHasALeaveOutListAndASmallRangeNotAMaximumOfTwelve() {
        for language in [NotesLanguage.polish, .english, .unknown] {
            let prompt = NotesPrompt.mapSystem(language: language)
            #expect(prompt.contains("Leave out"), "\(language)")
            #expect(prompt.contains("2 to 5"), "\(language)")
            #expect(prompt.contains("many hold none"), "\(language)")
            #expect(!prompt.contains("At most 12"), "\(language)")
        }
    }

    @Test func theReducePromptAsksForAChoiceOfFindingsAndQuestions() {
        #expect(NotesPrompt.reduceSystem.contains("FINDINGS"))
        #expect(NotesPrompt.reduceSystem.contains("at most 10"))
        #expect(NotesPrompt.reduceSystem.contains("QUESTIONS"))
    }
}
