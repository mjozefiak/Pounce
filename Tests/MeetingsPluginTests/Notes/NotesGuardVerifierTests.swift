import Foundation
import Testing

@testable import MeetingsPlugin

/// `NotesGuard.applyingVerifications`: what the semantic verifier's answers do to the guard's verdict (pure).
@Suite struct NotesGuardVerifierTests {
    /// Repaired for an invented name only: restorable.
    static let invented = GuardFixtures.point(
        "v1", .decision, quote: "Zatwierdzamy budżet marketingowy w wysokości czterdziestu tysięcy złotych",
        text: "Zatwierdzono budżet marketingowy dla Kowalskiego.", time: 21_000)
    /// A summary point that drifts from its quote: restorable.
    static let drifted = GuardFixtures.point(
        "v2", .summary, quote: "Zaczynamy spotkanie o budżecie na przyszły kwartał",
        text: "Rozmowa dotyczyła finansów firmy i planowania wydatków.", time: 5_000)
    /// The negation turned around: never sent.
    static let negated = GuardFixtures.point(
        "v3", .decision, quote: "Ja przygotuję umowę", text: "Umowa nie zostanie przygotowana.", time: 47_000)
    /// An invented name AND a negation the quote does not have: the negation rule would refuse it too, so it
    /// is not restorable.
    static let inventedAndNegated = GuardFixtures.point(
        "v4", .decision, quote: "Zatwierdzamy budżet marketingowy w wysokości czterdziestu tysięcy złotych",
        text: "Budżet dla Kowalskiego nie został zatwierdzony.", time: 21_000)
    /// A decision that is a question: downgraded, never sent.
    static let question = GuardFixtures.point(
        "v5", .decision, quote: "Kto zajmie się fakturami od dostawcy", text: "Ustalono, kto zajmie się fakturami.",
        time: 62_000)

    private static func checked(_ points: [NotesPoint]) -> NotesGuard.PointVerdict {
        NotesGuard(utterances: GuardFixtures.transcript()).verifyPoints(points)
    }

    private static func answered(_ verdict: NotesVerdict) -> NotesVerification {
        NotesVerification(verdict: verdict, source: .answered)
    }

    private static func review(_ verdict: NotesGuard.PointVerdict, _ id: String) -> NotesGuard.PointReview? {
        verdict.reviews.first { $0.id == id }
    }

    @Test func theRepairsCarryTheModelTextOnlyWhenTheVerifierMayUndoThem() {
        let verdict = Self.checked([
            Self.invented, Self.drifted, Self.negated, Self.inventedAndNegated, Self.question, GuardFixtures.offer,
        ])
        #expect(verdict.reviews.map(\.id) == verdict.verified.map(\.id))
        #expect(Self.review(verdict, "v1")?.repair == .unsupportedDetail)
        #expect(Self.review(verdict, "v1")?.modelText == Self.invented.text)
        #expect(Self.review(verdict, "v2")?.repair == .driftedFromQuote)
        #expect(Self.review(verdict, "v2")?.modelText == Self.drifted.text)
        #expect(Self.review(verdict, "v3")?.repair == .negationChanged)
        #expect(Self.review(verdict, "v3")?.modelText == nil)
        #expect(Self.review(verdict, "v4")?.repair == .unsupportedDetail)
        #expect(Self.review(verdict, "v4")?.modelText == nil)
        #expect(Self.review(verdict, "v5")?.repair == .downgradedQuestion)
        #expect(Self.review(verdict, "v5")?.modelText == nil)
        #expect(Self.review(verdict, GuardFixtures.offer.id)?.repair == nil)
        #expect(Self.review(verdict, GuardFixtures.offer.id)?.modelText == nil)
        // The claims: the model's text of a restorable repair, the kept text of a kept point, nothing else.
        let claims = Dictionary(
            uniqueKeysWithValues: zip(verdict.verified, verdict.reviews).map { ($0.id, $1.claim(of: $0)) })
        #expect(claims["v1"] == Self.invented.text)
        #expect(claims["v2"] == Self.drifted.text)
        #expect(claims["v3"] == .some(nil))
        #expect(claims["v4"] == .some(nil))
        #expect(claims["v5"] == .some(nil))
        #expect(claims[GuardFixtures.offer.id] == GuardFixtures.offer.text)
    }

    @Test func supportedRestoresTheModelTextAndNothingElse() {
        let before = Self.checked([Self.invented, Self.drifted])
        let (after, effect) = NotesGuard.applyingVerifications(
            ["v1": Self.answered(.supported), "v2": Self.answered(.supported)], to: before)
        #expect(effect == NotesGuard.VerifierEffect(restoredModelText: 2, rejectedKept: 0))
        #expect(after.verified.map(\.text) == [Self.invented.text, Self.drifted.text])
        // Only the text changes: the quote is the transcript's, kind and time as the guard set them.
        for (old, new) in zip(before.verified, after.verified) {
            #expect(new.quote == old.quote)
            #expect(new.kind == old.kind)
            #expect(new.timeMs == old.timeMs)
            #expect(new.person == old.person)
            #expect(new.due == old.due)
        }
        #expect(after.repaired == before.repaired - 2)
        #expect(after.repairReasons[.unsupportedDetail] == nil)
        #expect(after.repairReasons[.driftedFromQuote] == nil)
    }

    @Test func weakerUnsupportedAndFailedLeaveTheExcerpt() {
        let before = Self.checked([Self.invented, Self.drifted])
        for verification in [
            Self.answered(.weaker), Self.answered(.unsupported),
            NotesVerification(verdict: .unsupported, source: .malformed),
            NotesVerification(verdict: .unsupported, source: .failed),
            NotesVerification(verdict: .unsupported, source: .cutOff),
            NotesVerification(verdict: .unsupported, source: .cancelled),
        ] {
            let (after, effect) = NotesGuard.applyingVerifications(
                ["v1": verification, "v2": verification], to: before)
            #expect(after == before, "\(verification)")
            #expect(effect == NotesGuard.VerifierEffect())
        }
        // No verdict at all (the time ran out) is the same.
        #expect(NotesGuard.applyingVerifications([:], to: before).verdict == before)
    }

    @Test func aSupportedAnswerForANegationOrQuestionRepairChangesNothing() {
        let before = Self.checked([Self.negated, Self.inventedAndNegated, Self.question])
        let all = ["v3", "v4", "v5"].reduce(into: [String: NotesVerification]()) { $0[$1] = Self.answered(.supported) }
        let (after, effect) = NotesGuard.applyingVerifications(all, to: before)
        #expect(after == before)
        #expect(effect == NotesGuard.VerifierEffect())
    }

    @Test func aKeptPointRejectedByTheVerifierShowsItsQuote() throws {
        let before = Self.checked([GuardFixtures.budget, GuardFixtures.offer])
        #expect(before.repaired == 0)
        let (after, effect) = NotesGuard.applyingVerifications(
            [GuardFixtures.budget.id: Self.answered(.weaker), GuardFixtures.offer.id: Self.answered(.unsupported)],
            to: before)
        #expect(effect == NotesGuard.VerifierEffect(restoredModelText: 0, rejectedKept: 2))
        #expect(after.repaired == 2)
        #expect(after.repairReasons == [.verifierRejected: 2])
        #expect(after.verified.map(\.text) == before.verified.map(\.quote))
        // A task keeps the person and the due date the hard checks left it.
        let offer = try #require(after.verified.first { $0.id == GuardFixtures.offer.id })
        let checkedOffer = try #require(before.verified.first { $0.id == GuardFixtures.offer.id })
        #expect(offer.person == checkedOffer.person)
        #expect(offer.due == checkedOffer.due)
        #expect(after.reviews.allSatisfy { $0.repair == .verifierRejected })
    }

    @Test func aKeptPointWithAFailedOrSupportedVerdictIsUnchanged() {
        let before = Self.checked([GuardFixtures.budget, GuardFixtures.offer])
        for verification in [
            Self.answered(.supported), NotesVerification(verdict: .unsupported, source: .failed),
            NotesVerification(verdict: .unsupported, source: .malformed),
        ] {
            let (after, effect) = NotesGuard.applyingVerifications(
                [GuardFixtures.budget.id: verification, GuardFixtures.offer.id: verification], to: before)
            #expect(after == before, "\(verification)")
            #expect(effect == NotesGuard.VerifierEffect())
        }
    }

    @Test func theRequestHoldsTheClaimTheQuoteAndTwoUtterancesEachSide() throws {
        let notesGuard = NotesGuard(utterances: GuardFixtures.transcript())
        let verdict = notesGuard.verifyPoints([GuardFixtures.offer])
        let point = try #require(verdict.verified.first)
        let request = notesGuard.verificationRequest(for: point, claim: "Wysłać ofertę do klienta.")
        #expect(request.kind == .task)
        #expect(request.text == "Wysłać ofertę do klienta.")
        #expect(request.quote == point.quote)
        let transcript = GuardFixtures.transcript()
        #expect(request.context.map(\.text) == transcript[0...4].map(\.text))
        #expect(request.context.map(\.speaker) == transcript[0...4].map(\.speaker))

        // At the start of the meeting there is nothing before the quote.
        let first = try #require(notesGuard.verifyPoints([Self.drifted]).verified.first)
        let opening = notesGuard.verificationRequest(for: first, claim: "x")
        #expect(opening.context.map(\.text) == transcript[0...2].map(\.text))
    }
}
