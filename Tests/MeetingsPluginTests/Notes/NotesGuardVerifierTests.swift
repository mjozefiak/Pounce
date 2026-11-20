import Foundation
import Testing

@testable import MeetingsPlugin

/// `NotesGuard.applyingVerifications`: what the semantic verifier's answers do to the guard's verdict (pure).
/// A point the verifier doubts is REMOVED; its quote is never shown in its place.
@Suite struct NotesGuardVerifierTests {
    private static func checked(_ points: [NotesPoint]) -> NotesGuard.PointVerdict {
        NotesGuard(utterances: GuardFixtures.transcript()).verifyPoints(points)
    }

    private static func answered(_ verdict: NotesVerdict) -> NotesVerification {
        NotesVerification(verdict: verdict, source: .answered)
    }

    @Test func aPointTheVerifierDoubtsIsRemoved() {
        let before = Self.checked([GuardFixtures.budget, GuardFixtures.offer])
        #expect(before.verified.count == 2)
        let (after, effect) = NotesGuard.applyingVerifications(
            [GuardFixtures.budget.id: Self.answered(.weaker), GuardFixtures.offer.id: Self.answered(.unsupported)],
            to: before)
        #expect(effect == NotesGuard.VerifierEffect(rejected: 2))
        #expect(after.verified.isEmpty)
        #expect(after.dropped == before.dropped + 2)
        #expect(after.reasons[.verifierRejected] == 2)
    }

    @Test func onlyTheDoubtedPointGoes() {
        let before = Self.checked([GuardFixtures.budget, GuardFixtures.offer])
        let (after, effect) = NotesGuard.applyingVerifications(
            [GuardFixtures.budget.id: Self.answered(.supported), GuardFixtures.offer.id: Self.answered(.weaker)],
            to: before)
        #expect(effect.rejected == 1)
        #expect(after.verified.map(\.id) == [GuardFixtures.budget.id])
        // What stays is untouched.
        #expect(after.verified == before.verified.filter { $0.id == GuardFixtures.budget.id })
    }

    @Test func aSupportedFailedMalformedOrMissingAnswerChangesNothing() {
        let before = Self.checked([GuardFixtures.budget, GuardFixtures.offer])
        for verification in [
            Self.answered(.supported), NotesVerification(verdict: .unsupported, source: .failed),
            NotesVerification(verdict: .unsupported, source: .malformed),
            NotesVerification(verdict: .unsupported, source: .cutOff),
            NotesVerification(verdict: .unsupported, source: .cancelled),
        ] {
            let (after, effect) = NotesGuard.applyingVerifications(
                [GuardFixtures.budget.id: verification, GuardFixtures.offer.id: verification], to: before)
            #expect(after == before, "\(verification)")
            #expect(effect == NotesGuard.VerifierEffect())
        }
        // No verdict at all (the time ran out) is the same.
        #expect(NotesGuard.applyingVerifications([:], to: before).verdict == before)
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
        let first = try #require(
            notesGuard.verifyPoints([
                GuardFixtures.point(
                    "v2", .summary, quote: "Zaczynamy spotkanie o budżecie na przyszły kwartał",
                    text: "Zaczynamy spotkanie o budżecie.", time: 5_000)
            ]).verified.first)
        let opening = notesGuard.verificationRequest(for: first, claim: "x")
        #expect(opening.context.map(\.text) == transcript[0...2].map(\.text))
    }
}
