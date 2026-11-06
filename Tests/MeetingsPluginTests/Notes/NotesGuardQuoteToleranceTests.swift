import Foundation
import Testing

@testable import MeetingsPlugin

/// A point's quote may skip a few filler words of the transcript (quote match tolerance), never a negation, a
/// number or a name, never across a sentence or speaker, and never to get round the minimum quote length.
@Suite struct NotesGuardQuoteToleranceTests {
    private func guardrail(_ text: String) -> NotesGuard {
        NotesGuard(utterances: [NotesUtterance(startMs: 0, speaker: "Anna", text: text)])
    }

    private func check(_ text: String, quote: String, pointText: String = "Zrobimy 5 rzeczy.")
        -> NotesGuard.PointVerdict
    {
        guardrail(text).verifyPoints([GuardFixtures.point("p1", .summary, quote: quote, text: pointText)])
    }

    @Test func aQuoteMaySkipOneFillerWordAndTheRepairedTextComesFromTheTranscript() {
        let verdict = check("dha czy chciał nam przedstawić plan.", quote: "DHA chciał nam przedstawić")
        #expect(verdict.dropped == 0)
        #expect(verdict.repaired == 1)
        #expect(verdict.verified.first?.text.contains("czy") == true)
        #expect(verdict.verified.first?.quote.contains("czy") == true)
    }

    @Test func skippingThreeWordsIsNotAMatch() {
        let verdict = check("dha czy no wiec chciał nam przedstawić plan.", quote: "dha chciał nam przedstawić")
        #expect(verdict.reasons[.quoteNotInTranscript] == 1)
    }

    @Test func twoSkippedWordsInAllAreStillAMatch() {
        let verdict = check("dha czy chciał nam wlasnie przedstawić plan.", quote: "dha chciał nam przedstawić")
        #expect(verdict.dropped == 0)
    }

    @Test func aSkippedNegationIsNotAMatch() {
        let verdict = check("zatwierdzamy nie budżet marketingowy.", quote: "zatwierdzamy budżet marketingowy")
        #expect(verdict.reasons[.quoteNotInTranscript] == 1)
    }

    @Test func aSkippedNumberWordOrDigitIsNotAMatch() {
        let word = check("zatwierdzamy dwa budżety marketingowe.", quote: "zatwierdzamy budżety marketingowe")
        #expect(word.reasons[.quoteNotInTranscript] == 1)
        let digit = check("zatwierdzamy 40 budżetów marketingowych.", quote: "zatwierdzamy budżetów marketingowych")
        #expect(digit.reasons[.quoteNotInTranscript] == 1)
    }

    @Test func aSkippedNameIsNotAMatch() {
        let verdict = check("zatwierdzamy dla Marka budżet marketingowy.", quote: "zatwierdzamy budżet marketingowy")
        #expect(verdict.reasons[.quoteNotInTranscript] == 1)
    }

    @Test func anExactMatchWinsOverOneWithGaps() {
        let text = "dha czy chciał nam przedstawić plan. Potem dha chciał nam przedstawić wynik."
        let verdict = guardrail(text).verifyPoints([
            GuardFixtures.point(
                "p1", .summary, quote: "dha chciał nam przedstawić", text: "Zrobimy 5 rzeczy.", time: 0)
        ])
        #expect(verdict.dropped == 0)
        #expect(verdict.verified.first?.quote.contains("czy") == false)
    }

    @Test func aGapDoesNotCrossASentenceEnd() {
        let verdict = check(
            "Zatwierdzamy budżet. Marketingowy plan jest gotowy.", quote: "zatwierdzamy marketingowy plan")
        #expect(verdict.reasons[.quoteNotInTranscript] == 1)
    }

    @Test func aGapDoesNotCrossASpeakerChange() {
        let transcript = NotesGuard(utterances: [
            NotesUtterance(startMs: 0, speaker: "Anna", text: "Mamy wniosek o dodatkowe"),
            NotesUtterance(startMs: 3000, speaker: "Marek", text: "te środki na reklamę."),
        ])
        let verdict = transcript.verifyPoints([
            GuardFixtures.point("p1", .summary, quote: "wniosek o dodatkowe środki na reklamę", text: "Wniosek.")
        ])
        #expect(verdict.reasons[.quoteNotInTranscript] == 1)
    }

    @Test func aShortQuoteIsStillTooShortEvenWithGaps() {
        let verdict = check("dha czy chciał nam przedstawić plan.", quote: "dha chciał")
        #expect(verdict.reasons[.quoteTooShort] == 1)
        let whole = check("dha czy chciał", quote: "dha chciał")
        #expect(whole.reasons[.quoteTooShort] == 1)
    }
}
