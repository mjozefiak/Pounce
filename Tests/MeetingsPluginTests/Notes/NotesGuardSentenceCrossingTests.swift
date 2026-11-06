import Foundation
import Testing

@testable import MeetingsPlugin

/// A literal quote (no skipped words) may run over a sentence end when one speaker says all of it; a change of
/// speaker still blocks it, and a quote with a skipped word stays within one sentence.
@Suite struct NotesGuardSentenceCrossingTests {
    private static let twoSentences =
        "If it's not that urgent, I can take it. I just won't be able to get to it."
    private static let quote = "If it's not that urgent, I can take it. I just won't be able to get to it."

    private func verdict(_ utterances: [NotesUtterance], quote: String, kind: NotesPointKind = .summary)
        -> NotesGuard.PointVerdict
    {
        NotesGuard(utterances: utterances).verifyPoints([
            GuardFixtures.point(
                "p1", kind, quote: quote, text: "I can take it, but not soon.", person: nil)
        ])
    }

    @Test func aLiteralQuoteOfTwoSentencesBySameSpeakerInOneSegmentIsMatched() {
        let result = verdict(
            [NotesUtterance(startMs: 0, speaker: "Anna", text: Self.twoSentences)], quote: Self.quote)
        #expect(result.dropped == 0)
        // The shown quote is the transcript's text of both sentences.
        #expect(result.verified.first?.quote == Self.twoSentences)
    }

    @Test func aSentenceEndAtASpeakerChangeStillBlocksTheQuote() {
        let result = verdict(
            [
                NotesUtterance(startMs: 0, speaker: "Anna", text: "If it's not that urgent, I can take it."),
                NotesUtterance(startMs: 4000, speaker: "Marek", text: "I just won't be able to get to it."),
            ], quote: Self.quote)
        #expect(result.reasons[.quoteNotInTranscript] == 1)
    }

    @Test func aLiteralQuoteAcrossTwoSegmentsOfTheSameSpeakerIsMatched() {
        let result = verdict(
            [
                NotesUtterance(startMs: 0, speaker: "Anna", text: "If it's not that urgent, I can take it."),
                NotesUtterance(startMs: 4000, speaker: "Anna", text: "I just won't be able to get to it."),
            ], quote: Self.quote)
        #expect(result.dropped == 0)
        // The excerpt joins the pieces of the two segments; the full stop at the segment boundary is not kept.
        #expect(
            result.verified.first?.quote == "If it's not that urgent, I can take it I just won't be able to get to it.")
        #expect(result.verified.first?.utterance == 0)
    }

    @Test func aQuoteWithASkippedWordDoesNotCrossASentenceEnd() {
        // "really" is left out of the quote; the quote spans the sentence end.
        let result = verdict(
            [
                NotesUtterance(
                    startMs: 0, speaker: "Anna",
                    text: "If it's not that urgent, I can take it. I just won't really be able to get to it.")
            ], quote: Self.quote)
        #expect(result.reasons[.quoteNotInTranscript] == 1)
        // The same text with a gap inside one sentence still matches.
        let inside = verdict(
            [NotesUtterance(startMs: 0, speaker: "Anna", text: "I just won't really be able to get to it.")],
            quote: "I just won't be able to get to it")
        #expect(inside.dropped == 0)
    }

    @Test func aLiteralQuoteInOneSentenceAndAShortQuoteWorkAsBefore() {
        let transcript = [
            NotesUtterance(startMs: 0, speaker: "Anna", text: "I can take it. I just won't be able to get to it.")
        ]
        #expect(verdict(transcript, quote: "I just won't be able to get to it").dropped == 0)
        #expect(verdict(transcript, quote: "take it").reasons[.quoteTooShort] == 1)
    }

    @Test func aQuoteOverTwoSentencesRepairsFromBothAndTakesTheFirstSentenceAsItsPlace() {
        // A statement then a question: `sentence` and the question check look at the first sentence only.
        let transcript = [
            NotesUtterance(startMs: 0, speaker: "Anna", text: "We will ship on Friday. Who writes the notes?")
        ]
        let result = NotesGuard(utterances: transcript).verifyPoints([
            GuardFixtures.point(
                "p1", .decision, quote: "We will ship on Friday. Who writes the notes?",
                text: "Shipping moved to 12 May 2031.")
        ])
        #expect(result.dropped == 0)
        #expect(result.repaired == 1)
        // The replacement is the whole two-sentence excerpt: no length limit, no "first sentence" cut.
        #expect(result.verified.first?.text == "We will ship on Friday. Who writes the notes?")
        #expect(result.verified.first?.sentence == 0)
        #expect(result.verified.first?.kind == .decision)
    }
}
