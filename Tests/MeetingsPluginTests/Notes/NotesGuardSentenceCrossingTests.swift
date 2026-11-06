import Foundation
import Testing

@testable import MeetingsPlugin

/// A literal quote that runs on past a sentence end inside one speaker's words is matched on its first sentence
/// only (the rest of the quote is ignored), provided that part is long enough. A crossing at a speaker change, or
/// by a quote with a skipped word, is no match at all.
@Suite struct NotesGuardSentenceCrossingTests {
    private static let first = "If it's not that urgent, I can take it."
    private static let second = "I just won't be able to get to it."
    private static let both = first + " " + second

    private func verify(
        _ utterances: [NotesUtterance], quote: String, text: String = "I can take it if it is not urgent.",
        kind: NotesPointKind = .summary
    ) -> NotesGuard.PointVerdict {
        NotesGuard(utterances: utterances).verifyPoints([GuardFixtures.point("p1", kind, quote: quote, text: text)])
    }

    private func anna(_ text: String) -> [NotesUtterance] {
        [NotesUtterance(startMs: 0, speaker: "Anna", text: text)]
    }

    @Test func aTwoSentenceQuoteIsMatchedOnItsFirstSentenceOnly() {
        let result = verify(anna(Self.both), quote: Self.both)
        #expect(result.dropped == 0)
        #expect(result.repaired == 0)
        // The shown quote (the covered range) ends at the end of the first sentence, terminator included, and
        // holds nothing of the second.
        #expect(result.verified.first?.quote == Self.first)
        #expect(result.verified.first?.quote.contains("won't") == false)
    }

    @Test func aPointThatNeedsTheSecondSentenceIsRepairedToTheFirstOne() {
        // "next week" is in no word of the first sentence: the usual faithfulness check replaces the text.
        let result = verify(
            anna(Self.both), quote: Self.both, text: "I won't be able to get to it before next week.")
        #expect(result.dropped == 0)
        #expect(result.repaired == 1)
        #expect(result.verified.first?.text == Self.first)
        // A negation that only the second sentence has is not in the matched quote: the negation check
        // repairs the text to the first sentence.
        let transcript = anna("We ship on Friday. We will not ship on Monday.")
        let negated = verify(transcript, quote: "We ship on Friday. We will not ship", text: "We will not ship.")
        #expect(negated.repaired == 1)
        #expect(negated.verified.first?.text == "We ship on Friday.")
    }

    @Test func aQuestionTailAndTheNextStatementOfOneSpeakerAreStillNoMatch() {
        let result = verify(
            [
                NotesUtterance(startMs: 0, speaker: "Anna", text: "Czy to nie?"),
                NotesUtterance(startMs: 3000, speaker: "Anna", text: "Zatwierdzamy budżet"),
            ], quote: "nie zatwierdzamy budżet", text: "Odrzucono.", kind: .decision)
        #expect(result.reasons[.quoteNotInTranscript] == 1)
    }

    @Test func aCrossingAtASpeakerChangeIsStillNoMatch() {
        let result = verify(
            [
                NotesUtterance(startMs: 0, speaker: "Anna", text: Self.first),
                NotesUtterance(startMs: 4000, speaker: "Marek", text: Self.second),
            ], quote: Self.both)
        #expect(result.reasons[.quoteNotInTranscript] == 1)
    }

    @Test func aQuoteWithASkippedWordDoesNotCrossASentenceEnd() {
        let result = verify(
            anna("If it's not that urgent, I can take it. I just won't really be able to get to it."),
            quote: Self.both)
        #expect(result.reasons[.quoteNotInTranscript] == 1)
        // A gap inside one sentence still matches.
        let inside = verify(
            anna("I just won't really be able to get to it."), quote: "I just won't be able to get to it")
        #expect(inside.dropped == 0)
    }

    @Test func aSingleSentenceQuoteAndAShortQuoteWorkAsBefore() {
        let transcript = anna("I can take it. I just won't be able to get to it.")
        #expect(verify(transcript, quote: "I just won't be able to get to it").dropped == 0)
        #expect(verify(transcript, quote: "take it").reasons[.quoteTooShort] == 1)
    }

    @Test func aFirstSentenceOfExactlyTheMinimumIsEnough() {
        // Three words, then the sentence end; the quote runs into the second sentence.
        let transcript = anna("We ship Friday. Nobody objects to that plan.")
        let result = verify(
            transcript, quote: "We ship Friday. Nobody objects", text: "We ship on Friday.")
        #expect(result.dropped == 0)
        #expect(result.verified.first?.quote == "We ship Friday.")
        // Two words are below the minimum.
        let tooShort = verify(anna("We ship. Nobody objects to that plan."), quote: "We ship. Nobody objects")
        #expect(tooShort.reasons[.quoteNotInTranscript] == 1)
    }

    @Test func aCutRangeInTwoSegmentsOfOneSpeakerKeepsItsOwnTerminator() {
        // The first sentence is cut by the recognizer in two segments and the quote runs past its end: the
        // range ends with the sentence, so the terminator is shown and none of the next sentence.
        let result = verify(
            [
                NotesUtterance(startMs: 0, speaker: "Anna", text: "If it's not that urgent, I can"),
                NotesUtterance(startMs: 4000, speaker: "Anna", text: "take it. I just won't be able."),
            ], quote: "If it's not that urgent, I can take it. I just won't")
        #expect(result.dropped == 0)
        #expect(result.verified.first?.quote == "If it's not that urgent, I can take it.")
    }
}
