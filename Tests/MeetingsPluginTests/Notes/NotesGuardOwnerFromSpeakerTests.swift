import Foundation
import Testing

@testable import MeetingsPlugin

/// The guard gives a task without a person to the speaker of a first person singular quote.
@Suite struct NotesGuardOwnerFromSpeakerTests {
    private func utterances() -> [NotesUtterance] {
        [
            NotesUtterance(startMs: 1_000, speaker: "Tim", text: "I'll look into the login bug this week."),
            NotesUtterance(startMs: 11_000, speaker: "Nadia", text: "We'll review the pull requests together."),
            NotesUtterance(startMs: 21_000, speaker: "Speaker 2", text: "I'll write the release notes tomorrow."),
            NotesUtterance(startMs: 31_000, speaker: "Girish", text: "Okay so I will start"),
            NotesUtterance(startMs: 41_000, speaker: "Surya", text: "the thread about the flaky tests."),
            NotesUtterance(startMs: 51_000, speaker: "Ewa", text: "Zrobię to do piątku."),
            NotesUtterance(startMs: 61_000, speaker: "Tim", text: "Nadia will check the dashboards."),
            NotesUtterance(startMs: 71_000, speaker: "Girish", text: "I'll ping you offline Tim."),
            NotesUtterance(startMs: 81_000, speaker: "Tim", text: "I'll look into it."),
        ]
    }

    private func verify(
        _ kind: NotesPointKind = .task, quote: String, time: Int, person: String? = nil
    ) -> (NotesPoint?, NotesGuard.PointVerdict) {
        let point = GuardFixtures.point("p1", kind, quote: quote, text: quote, time: time, person: person)
        let verdict = NotesGuard(utterances: utterances()).verifyPoints([point])
        return (verdict.verified.first, verdict)
    }

    @Test func aNamedSpeakerOwnsWhatTheySayTheyWillDo() {
        let (point, verdict) = verify(quote: "I'll look into the login bug", time: 1_000)
        #expect(point?.kind == .task)
        #expect(point?.person == "Tim")
        #expect(verdict.ownerFromSpeaker == 1)
    }

    @Test func aPolishFirstPersonIsAssigned() {
        let (point, verdict) = verify(quote: "Zrobię to do piątku", time: 51_000)
        #expect(point?.person == "Ewa")
        #expect(verdict.ownerFromSpeaker == 1)
    }

    @Test func aPluralQuoteNamesNobody() {
        let (point, verdict) = verify(quote: "We'll review the pull requests together", time: 11_000)
        #expect(point?.kind == .task)
        #expect(point?.person == nil)
        #expect(verdict.ownerFromSpeaker == 0)
    }

    @Test func aGenericLabelIsNeverAnOwner() {
        let (point, verdict) = verify(quote: "I'll write the release notes tomorrow", time: 21_000)
        #expect(point?.kind == .task)
        #expect(point?.person == nil)
        #expect(verdict.ownerFromSpeaker == 0)
    }

    @Test func aQuoteAcrossTwoSpeakersIsNotAssigned() {
        let (point, verdict) = verify(
            quote: "I will start the thread about the flaky tests", time: 31_000)
        if let point { #expect(point.person == nil) }
        #expect(verdict.ownerFromSpeaker == 0)
    }

    @Test func aPersonTheModelNamedIsCheckedAsBefore() {
        // The model's name is in the quote: kept, and not the speaker's.
        let (named, namedVerdict) = verify(quote: "I'll ping you offline Tim", time: 71_000, person: "Tim")
        #expect(named?.person != "Girish")
        #expect(namedVerdict.ownerFromSpeaker == 0)
        // A name that is neither in the quote nor the speaker's is dropped, and the guard does not fill it.
        let (wrong, wrongVerdict) = verify(quote: "I'll look into the login bug", time: 1_000, person: "Marek")
        #expect(wrong?.person == nil)
        #expect(wrongVerdict.ownerFromSpeaker == 0)
        // The speaker's own name from the model is kept by the existing rule, not counted as given by the guard.
        let (own, ownVerdict) = verify(quote: "I'll look into the login bug", time: 1_000, person: "Tim")
        #expect(own?.person == "Tim")
        #expect(ownVerdict.ownerFromSpeaker == 0)
    }

    @Test func anotherNameInTheQuoteDoesNotTakeTheOwnerFromTheSpeaker() {
        let (point, _) = verify(quote: "I'll ping you offline Tim", time: 71_000)
        #expect(point?.person == "Girish")
    }

    @Test func otherKindsGetNoOwner() {
        let (decision, verdict) = verify(.decision, quote: "I'll look into the login bug", time: 1_000)
        #expect(decision?.person == nil)
        let (summary, _) = verify(.summary, quote: "I'll look into the login bug", time: 1_000)
        #expect(summary?.person == nil)
        #expect(verdict.ownerFromSpeaker == 0)
    }

    @Test func theTraceCountsTheDecisionAndHoldsNoText() throws {
        let (_, verdict) = verify(quote: "I'll look into the login bug", time: 1_000)
        let verification = NotesTraceVerification(proposed: 1, verdict: verdict)
        #expect(verification.ownerFromSpeaker == 1)
        let data = try JSONEncoder().encode(verification)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("Tim"))
        #expect(!json.contains("login"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ownerFromSpeaker"] as? Int == 1)
        #expect(try JSONDecoder().decode(NotesTraceVerification.self, from: data) == verification)

        // An older trace has no such field.
        var older = object
        older.removeValue(forKey: "ownerFromSpeaker")
        let decoded = try JSONDecoder().decode(
            NotesTraceVerification.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(decoded.ownerFromSpeaker == 0)
    }
}
