import Foundation
import Testing

@testable import MeetingsPlugin

/// Why the guard refuses the model's summary paragraph: the reason is an enum, written to the audit and the
/// trace, never any text.
@Suite struct NotesSummaryRefusalTests {
    let guardrail = NotesGuard(utterances: GuardFixtures.transcript())
    let points = GuardFixtures.verified

    private func audit(_ summary: String) -> NotesGuard.ReduceAudit {
        guardrail.auditedVerifyReduce(
            NotesReduceOutput(decisions: ["p1"], tasks: ["p2", "p3"], questions: ["p4"], summary: summary),
            points: points
        ).audit
    }

    @Test(
        "A refused paragraph carries the rule that refused it",
        arguments: [
            ("Zatwierdzono budżet w wysokości 50 tysięcy złotych.", NotesGuard.SummaryRefusal.unsupportedNumber),
            ("Spotkanie odbyło się we wtorek i dotyczyło budżetu.", .unsupportedCalendarWord),
            ("Spotkanie dotyczyło budżetu, a decyzję podpisał dyrektor Nowak.", .unsupportedCapitalised),
            ("Kowalski zatwierdził budżet.", .unsupportedSentenceStart),
            ("Spotkanie dotyczyło budżetu, nie ofert.", .negation),
            (
                "The meeting covered the budget for the next quarter and it was approved by the team.",
                .languageChanged
            ),
            (Array(repeating: "budżet", count: 200).joined(separator: " ") + ".", .tooManyWords),
            (String(repeating: "x", count: 1600), .tooLong),
        ])
    func theRefusalIsRecorded(summary: String, expected: NotesGuard.SummaryRefusal) {
        let result = audit(summary)
        #expect(result.summaryOrigin == .composedAfterRefusal)
        #expect(result.summaryRefusal == expected)
    }

    @Test func aPassingParagraphHasNoRefusal() {
        let result = audit("Spotkanie dotyczyło budżetu na przyszły kwartał.")
        #expect(result.summaryOrigin == .model)
        #expect(result.summaryRefusal == nil)
    }

    @Test func theTraceCarriesTheRefusalAndAnOlderTraceDecodes() throws {
        let summary = NotesTraceSummary(
            origin: .composedAfterRefusal, present: true, shown: true, sourceIDs: ["p5"], refusal: .negation)
        let data = try JSONEncoder().encode(summary)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["refusal"] as? String == "negation")
        #expect(try JSONDecoder().decode(NotesTraceSummary.self, from: data) == summary)

        let older = Data(
            #"{"origin":"composedAfterRefusal","present":true,"shown":true,"sourceIDs":["p5"]}"#.utf8)
        let decoded = try JSONDecoder().decode(NotesTraceSummary.self, from: older)
        #expect(decoded.refusal == nil)
        #expect(decoded.origin == .composedAfterRefusal)
    }
}
