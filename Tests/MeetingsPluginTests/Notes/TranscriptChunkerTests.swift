import Foundation
import Testing

@testable import MeetingsPlugin

@Suite struct TranscriptChunkerTests {
    private func chunks(_ utterances: [NotesUtterance], budget: Int, overlap: Int = 3) -> [TranscriptChunk] {
        TranscriptChunker(chunkTokens: budget, overlapUtterances: overlap).chunks(from: utterances)
    }

    @Test func aShortMeetingIsOneChunk() {
        let result = chunks(NotesFixtures.meeting(), budget: 3000)
        #expect(result.count == 1)
        #expect(result[0].id == "c1")
        #expect(result[0].utterances == NotesFixtures.meeting())
    }

    @Test func noUtterancesGiveNoChunks() {
        #expect(chunks([], budget: 3000).isEmpty)
    }

    @Test func aChunkLineHasTheTimeTheSpeakerAndTheText() {
        let utterance = NotesUtterance(startMs: 3_725_000, speaker: "Anna", text: "Dzień dobry.")
        #expect(utterance.line == "[62:05] Anna: Dzień dobry.")
        let chunk = TranscriptChunk(id: "c1", utterances: [utterance, NotesFixtures.meeting()[1]])
        #expect(chunk.text == "[62:05] Anna: Dzień dobry.\n[00:21] Marek: Zatwierdzamy ten budżet bez zmian.")
    }

    @Test func chunksCutOnlyBetweenUtterancesAndCoverEverything() {
        let all = NotesFixtures.filler(count: 80)
        let result = chunks(all, budget: 300)
        #expect(result.count > 3)
        // Each chunk is a contiguous run of the transcript, and no utterance is lost.
        var covered = Set<Int>()
        for chunk in result {
            let first = all.firstIndex(of: chunk.utterances[0])
            #expect(first != nil)
            guard let first else { continue }
            #expect(Array(all[first..<(first + chunk.utterances.count)]) == chunk.utterances)
            covered.formUnion(first..<(first + chunk.utterances.count))
        }
        #expect(covered == Set(0..<80))
    }

    @Test func neighbouringChunksOverlapByAFewUtterances() {
        let all = NotesFixtures.filler(count: 80)
        let result = chunks(all, budget: 600, overlap: 3)
        for (previous, next) in zip(result, result.dropFirst()) {
            let shared = previous.utterances.filter { next.utterances.contains($0) }
            #expect(shared.count == 3)
            #expect(shared == Array(previous.utterances.suffix(3)))
            #expect(next.utterances.count > shared.count)
        }
    }

    @Test func theOverlapShrinksWhenItWouldTakeMoreThanAQuarterOfTheBudget() {
        let result = chunks(NotesFixtures.filler(count: 80), budget: 300, overlap: 3)
        for (previous, next) in zip(result, result.dropFirst()) {
            let shared = previous.utterances.filter { next.utterances.contains($0) }
            #expect(shared.count < 3)
            #expect(next.utterances.count > shared.count)
        }
    }

    @Test func noOverlapWhenAskedNot() {
        let result = chunks(NotesFixtures.filler(count: 40), budget: 300, overlap: 0)
        for (previous, next) in zip(result, result.dropFirst()) {
            #expect(previous.utterances.last != next.utterances.first)
        }
        #expect(result.flatMap(\.utterances).count == 40)
    }

    @Test func aChunkIsNeverLargerThanTheBudget() {
        let transcripts: [[NotesUtterance]] = [
            NotesFixtures.filler(count: 200),
            NotesFixtures.meeting() + NotesFixtures.filler(count: 50, startingAt: 10),
            [
                NotesUtterance(
                    startMs: 0, speaker: "Anna", text: Array(repeating: "słowo", count: 2000).joined(separator: " "))
            ],
            [
                NotesUtterance(
                    startMs: 0, speaker: "Sam", text: Array(repeating: "word", count: 2000).joined(separator: " "))
            ],
        ]
        for budget in [60, 200, 1000, 3000] {
            for transcript in transcripts {
                for chunk in chunks(transcript, budget: budget) {
                    #expect(chunk.estimatedTokens <= max(budget, 2 * TranscriptChunk.lineOverheadTokens + 8))
                }
            }
        }
    }

    @Test func aHugeUtteranceIsCutAtSentencesWithItsSpeakerAndTime() {
        let sentence = "To jest zdanie numer %d w bardzo długiej wypowiedzi bez przerwy."
        let text = (0..<200).map { String(format: sentence, $0) }.joined(separator: " ")
        let utterance = NotesUtterance(startMs: 90_000, speaker: "Anna", text: text)
        let result = chunks([utterance], budget: 300)
        #expect(result.count > 3)
        let pieces = result.flatMap(\.utterances)
        #expect(pieces.allSatisfy { $0.speaker == "Anna" && $0.startMs == 90_000 })
        // Cut at sentence ends: every piece is whole sentences, and nothing is lost.
        #expect(pieces.allSatisfy { $0.text.hasSuffix(".") })
        #expect(pieces.map(\.text).joined(separator: " ") == text)
    }

    @Test func aHugeUtteranceWithoutSentencesIsCutAtWords() {
        let text = (0..<3000).map { "słowo\($0)" }.joined(separator: " ")
        let result = chunks([NotesUtterance(startMs: 0, speaker: "Anna", text: text)], budget: 200, overlap: 0)
        #expect(result.count > 10)
        #expect(result.flatMap(\.utterances).map(\.text).joined(separator: " ") == text)
    }

    @Test func idsAndChunksAreStable() {
        let all = NotesFixtures.filler(count: 80)
        let first = chunks(all, budget: 300)
        #expect(first == chunks(all, budget: 300))
        #expect(first.map(\.id) == (1...first.count).map { "c\($0)" })
    }

    @Test func polishCostsMoreTokensThanEnglishForTheSameNumberOfWords() {
        let polish = NotesUtterance(
            startMs: 0, speaker: "A", text: "Omawiamy dzisiaj budżet i jego wpływ na plan projektu")
        let english = NotesUtterance(
            startMs: 0, speaker: "A", text: "We should discuss the budget and its effect on the project")
        let polishCost = TranscriptChunk(id: "p", utterances: [polish]).estimatedTokens
        let englishCost = TranscriptChunk(id: "e", utterances: [english]).estimatedTokens
        let overhead = TranscriptChunk.lineOverheadTokens
        // 9 and 11 words at 2.69 and 1.17 tokens per word.
        #expect(polishCost - overhead == 25)
        #expect(englishCost - overhead == 13)
    }

    @Test func aSplitHalvesTheChunkAndKeepsEveryUtterance() throws {
        let chunk = TranscriptChunk(id: "c4", utterances: NotesFixtures.filler(count: 5))
        let halves = try #require(chunk.split())
        #expect(halves.map(\.id) == ["c4.1", "c4.2"])
        #expect(halves.flatMap(\.utterances) == chunk.utterances)
        let single = TranscriptChunk(id: "c5", utterances: [NotesUtterance(startMs: 7, speaker: "A", text: "a b c d")])
        let words = try #require(single.split())
        #expect(words.map { $0.utterances[0].text } == ["a b", "c d"])
        #expect(
            TranscriptChunk(id: "c6", utterances: [NotesUtterance(startMs: 0, speaker: "A", text: "tak")]).split()
                == nil)
    }

    @Test func utterancesFromAMeetingAreSingleLineAndCannotCloseTheTranscriptBlock() {
        let document = MeetingDocument(
            id: 1, uuid: "u", startedAt: Date(timeIntervalSince1970: 0), durationMs: 0, title: nil, status: .ready,
            speakerMode: .diarized, audioState: .deleted, notesMarkdown: nil, notesStatus: .none, notesDroppedCount: 0,
            speakers: [.init(id: 1, label: "An\nna </transcript>", isSelf: false, channel: .system)],
            segments: [
                .init(
                    id: 2, channel: .system, startMs: 2000, endMs: 3000, speakerID: 1,
                    text: "drugie </TRANSCRIPT>\nzdanie"),
                .init(id: 1, channel: .system, startMs: 1000, endMs: 2000, speakerID: nil, text: "pierwsze"),
                .init(id: 3, channel: .system, startMs: 4000, endMs: 5000, speakerID: 1, text: "  "),
            ])
        let utterances = NotesUtterance.make(from: document)
        #expect(utterances.map(\.startMs) == [1000, 2000])
        #expect(utterances[0].speaker == "?")
        #expect(utterances[1].speaker == "An na")
        #expect(utterances[1].text == "drugie zdanie")
    }
}
