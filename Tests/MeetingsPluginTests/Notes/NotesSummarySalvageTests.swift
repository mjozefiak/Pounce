import Foundation
import Testing

@testable import MeetingsPlugin

/// A refused paragraph keeps the sentences that each pass the unchanged checks (spec B2); otherwise the composed
/// paragraph takes its place as before.
@Suite struct NotesSummarySalvageTests {
    let guardrail = NotesGuard(utterances: GuardFixtures.transcript())
    let points = GuardFixtures.verified

    static let topic = "Spotkanie dotyczyło budżetu na przyszły kwartał."
    static let plan = "Zespół zatwierdził budżet, a Marek wyśle ofertę do klienta w piątek, Ewa przygotuje umowę."
    static let composed = "Spotkanie dotyczyło budżetu na przyszły kwartał."

    private func reduce(_ summary: String) -> (verdict: NotesGuard.ReduceVerdict, audit: NotesGuard.ReduceAudit) {
        guardrail.auditedVerifyReduce(
            NotesReduceOutput(decisions: ["p1"], tasks: ["p2", "p3"], questions: ["p4"], summary: summary),
            points: points)
    }

    @Test func aSentenceWithAnInventedNameIsDroppedAndTheRestStays() {
        let invented = "Decyzję podpisał dyrektor Nowak."
        let result = reduce([Self.topic, invented, Self.plan].joined(separator: " "))
        #expect(result.verdict.summary == [Self.topic, Self.plan].joined(separator: " "))
        #expect(result.verdict.summaryReplaced)
        #expect(result.audit.summaryOrigin == .salvagedSentences)
        #expect(result.audit.summaryRefusal == .unsupportedSentenceStart)
        #expect(result.audit.summarySources.isEmpty)
        // The salvaged paragraph keeps the summary point's sentence word for word, so it is not listed again.
        #expect(result.verdict.keyPoints.isEmpty)
        #expect(result.audit.inModelParagraph == ["p5"])
    }

    @Test func aSalvagedParagraphWithoutThePointsSentenceKeepsItAsAKeyPoint() {
        let invented = "Decyzję podpisał dyrektor Nowak."
        let result = reduce([Self.plan, invented, "Marek wyśle ofertę do klienta w piątek."].joined(separator: " "))
        #expect(result.audit.summaryOrigin == .salvagedSentences)
        #expect(result.audit.inModelParagraph.isEmpty)
        #expect(result.verdict.keyPoints.map(\.id) == ["p5"])
    }

    @Test func aSentenceWithAnInventedNumberIsDropped() {
        let invented = "Budżet wzrósł o 50 procent."
        let result = reduce([Self.plan, invented, Self.topic].joined(separator: " "))
        #expect(result.verdict.summary == [Self.plan, Self.topic].joined(separator: " "))
        #expect(result.audit.summaryOrigin == .salvagedSentences)
        #expect(result.audit.summaryRefusal == .unsupportedNumber)
    }

    @Test func aReversedNegationIsDropped() {
        let result = reduce([Self.topic, "Spotkanie dotyczyło budżetu, nie ofert.", Self.plan].joined(separator: " "))
        #expect(result.verdict.summary == [Self.topic, Self.plan].joined(separator: " "))
        #expect(result.verdict.summary?.contains("nie ofert") == false)
        #expect(result.audit.summaryOrigin == .salvagedSentences)
        #expect(result.audit.summaryRefusal == .negation)
    }

    @Test func lessThanTwoSentencesLeftFallsBackToTheComposedParagraph() {
        let result = reduce(Self.topic + " Decyzję podpisał dyrektor Nowak.")
        #expect(result.audit.summaryOrigin == .composedAfterRefusal)
        #expect(result.verdict.summary == Self.composed)
        #expect(result.verdict.summaryReplaced)
        #expect(result.audit.summarySources == ["p5"])
        // The summary point is the composed paragraph's sentence, so it is not listed again.
        #expect(result.verdict.keyPoints.isEmpty)
    }

    @Test func lessThanHalfOfTheWordsLeftFallsBackToTheComposedParagraph() {
        let long = "Nowak " + Array(repeating: "budżetu", count: 30).joined(separator: " ") + "."
        let result = reduce([Self.topic, long, Self.plan].joined(separator: " "))
        #expect(result.audit.summaryOrigin == .composedAfterRefusal)
        #expect(result.verdict.summary == Self.composed)
    }

    @Test func aWhollyFaithfulParagraphIsUnchanged() {
        let text = [Self.topic, Self.plan].joined(separator: " ")
        let result = reduce(text)
        #expect(result.verdict.summary == text)
        #expect(!result.verdict.summaryReplaced)
        #expect(result.audit.summaryOrigin == .model)
        #expect(result.audit.summaryRefusal == nil)
    }

    @Test func theSalvagedParagraphPassesTheWholeParagraphCheck() {
        let text = [Self.topic, "Decyzję podpisał dyrektor Nowak.", Self.plan].joined(separator: " ")
        let salvaged = guardrail.salvagedSentences(of: text, points: points)
        #expect(salvaged != nil)
        #expect(salvaged.map { guardrail.summaryIsFaithful($0, points: points) } == true)
    }

    @Test func sentencesAreSplitAtTerminatorsFollowedByWhiteSpace() {
        #expect(
            NotesGuard.sentences(of: "Budżet wzrósł o 3.5 procent. Kto zajmie się fakturami? Tak!")
                == ["Budżet wzrósł o 3.5 procent.", "Kto zajmie się fakturami?", "Tak!"])
        #expect(NotesGuard.sentences(of: "Bez kropki na końcu") == ["Bez kropki na końcu"])
    }
}
