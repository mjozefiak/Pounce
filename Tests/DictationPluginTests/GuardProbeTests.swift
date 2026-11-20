import Foundation
import Testing

@testable import DictationPlugin

/// A faithful copy of the check `main` ran on every chunk before the self-correction work: the answer
/// openings, the length range and the language. `FormatterGuard` must give exactly this verdict, except that a
/// chunk it accepts is turned back into the raw text when `negationBeforeMarker` holds (owner decision
/// 2026-11-20, variant A).
enum MainGuardReference {
    static func check(input: String, output rawOutput: String) -> FormatterGuard.Verdict {
        let output = FormatterGuard.clean(rawOutput)
        guard !output.isEmpty else { return .rejected(.empty) }
        let openings = [
            "oto ", "oczywiście", "jasne,", "jasne!", "sure,", "sure!", "sure.", "certainly", "of course",
            "here is", "here's", "here are", "i can't", "i cannot", "as an ai", "przepraszam",
        ]
        let lower = output.lowercased()
        let said = input.lowercased()
        if openings.contains(where: {
            lower.hasPrefix($0) && !said.contains($0.trimmingCharacters(in: .punctuationCharacters))
        }) {
            return .rejected(.answered)
        }
        let inputWords = FormatterGuard.words(in: input)
        let outputWords = FormatterGuard.words(in: output)
        if inputWords >= 5 {
            let ratio = Double(outputWords) / Double(inputWords)
            if ratio > 1.15 { return .rejected(.tooLong) }
            if ratio < 0.6 { return .rejected(.tooShort) }
        } else if outputWords > inputWords + 3 {
            return .rejected(.tooLong)
        }
        let before = Language.dominant(in: input)
        let after = Language.dominant(in: output)
        if before != .unknown, after != .unknown, before != after { return .rejected(.languageChanged) }
        return .accepted(output)
    }

    /// What `FormatterGuard` must return: `main`'s verdict, or the one new reason for a chunk `main` accepts.
    static func expected(input: String, output: String) -> FormatterGuard.Verdict {
        let verdict = check(input: input, output: output)
        if case .accepted = verdict, FormatterGuard.negationBeforeMarker(in: input) {
            return .rejected(.negationBeforeMarker)
        }
        return verdict
    }
}

/// Runs `GuardProbeTable` (every probe of the review rounds, all invented) against `FormatterGuard`. The tables
/// are documentation of known behaviour: they show what the guard of variant A does and does not see.
@Suite struct GuardProbeTests {
    private func accepted(_ input: String, _ output: String) -> Bool {
        if case .accepted = FormatterGuard.check(input: input, output: output) { return true }
        return false
    }

    private func mainAccepts(_ input: String, _ output: String) -> Bool {
        if case .accepted = MainGuardReference.check(input: input, output: output) { return true }
        return false
    }

    static let table =
        GuardProbeTable.rounds12 + GuardProbeTable.round3 + GuardProbeTable.round4
        + GuardProbeTable.round5 + GuardProbeTable.round6 + GuardProbeTable.round7 + GuardProbeTable.round8

    /// Outside the negation rule the verdict of every probe is the verdict of `main`.
    @Test func everyProbeGetsTheVerdictOfMainExceptTheNegationRule() {
        for row in Self.table {
            #expect(
                FormatterGuard.check(input: row.input, output: row.output)
                    == MainGuardReference.expected(input: row.input, output: row.output),
                "\(row.id)")
        }
    }

    /// The probes of the fifth verification that turn the sentence round or lose content behind a negation
    /// before the span: all of them are rejected now.
    @Test func theNegationProbesOfRound5AreRejected() {
        var checked = 0
        for row in GuardProbeTable.round8 where !row.ok && FormatterGuard.negationBeforeMarker(in: row.input) {
            checked += 1
            #expect(!accepted(row.input, row.output), "\(row.id): \(row.output)")
        }
        #expect(checked >= 10)
        for id in ["G1", "G2", "G3", "G9", "G12", "S4", "S9"] {
            let row = GuardProbeTable.round8.first { $0.id == "R5-\(id)" }
            #expect(row.map { !accepted($0.input, $0.output) } == true, "\(id)")
        }
    }

    /// Known limits, counted and printed so they are not hidden: texts that lose the final version, keep both
    /// versions or change a number, and that the guard accepts. Every one is accepted by `main` too, because
    /// outside the negation rule the guard IS `main`'s. The numbers go to the PR body and ADR 0010.
    @Test func theLimitsTheGuardAcceptsAreTheOnesOfMain() {
        var accepting: [String] = []
        var withMarker = 0
        var bad = 0
        var badWithMarker = 0
        for row in Self.table where !row.ok {
            bad += 1
            if FormatterGuard.firstMarker(in: FormatterGuard.tokens(row.input)) != nil { badWithMarker += 1 }
            if accepted(row.input, row.output) {
                accepting.append(row.id)
                #expect(mainAccepts(row.input, row.output), "\(row.id) is accepted by the guard but not by main")
                if FormatterGuard.firstMarker(in: FormatterGuard.tokens(row.input)) != nil { withMarker += 1 }
            }
        }
        print(
            "[guard-probes] bad texts \(bad) (\(badWithMarker) with a marker), accepted by the guard \(accepting.count) (with a marker "
                + "\(withMarker)): \(accepting.sorted())")
        #expect(accepting.count == Self.knownAccepted)
        #expect(bad == Self.badProbes)
        #expect(badWithMarker == Self.badProbesWithMarker)
        #expect(withMarker == Self.knownAcceptedWithMarker)
    }

    /// Correct cleanups the guard turns into the raw text (fail-safe): `main`'s length range plus the rule.
    @Test func correctCleanupsFallingBackAreCounted() {
        var fallbacks: [String] = []
        var byNegation = 0
        var total = 0
        for row in Self.table where row.ok {
            total += 1
            if !accepted(row.input, row.output) {
                fallbacks.append(row.id)
                if FormatterGuard.check(input: row.input, output: row.output) == .rejected(.negationBeforeMarker) {
                    byNegation += 1
                }
            }
        }
        print("[guard-probes] correct cleanups \(total), raw fallbacks \(fallbacks.count), by negation \(byNegation)")
        #expect(fallbacks.count == Self.correctFallbacks)
        #expect(byNegation == Self.correctFallbacksByNegation)
    }

    static let badProbes = 210
    static let badProbesWithMarker = 189
    static let knownAccepted = 70
    static let knownAcceptedWithMarker = 49
    static let correctFallbacks = 70
    static let correctFallbacksByNegation = 2

    // MARK: Chunks without a marker

    /// Spoken and written form of the same sentence parts; a chunk is some of them in order, so the written text
    /// always matches the spoken one part by part.
    private static let polishParts: [(spoken: String, written: String)] = [
        ("ostatnio dużo pracujemy nad nowym modułem raportów", "Ostatnio dużo pracujemy nad nowym modułem raportów"),
        ("i musimy dopracować wiele drobnych szczegółów", "i musimy dopracować wiele drobnych szczegółów,"),
        ("zanim pokażemy go klientowi na spotkaniu", "zanim pokażemy go klientowi na spotkaniu"),
        ("w przyszłym tygodniu więc proszę", "w przyszłym tygodniu, więc proszę,"),
        ("żeby każdy przejrzał swoje zadania", "żeby każdy przejrzał swoje zadania"),
    ]
    private static let englishParts: [(spoken: String, written: String)] = [
        (
            "we are going through the whole list of open issues before the release",
            "We're going through the whole list of open issues before the release,"
        ),
        (
            "because it is blocking the client and they are waiting for a clear answer from us",
            "because it's blocking the client, and they're waiting for a clear answer from us"
        ),
        (
            "by the end of the week otherwise they will escalate it",
            "by the end of the week. Otherwise, they'll escalate it,"
        ),
        ("and we do not want that", "and we don't want that"),
    ]

    /// What a speaker adds at the end of a chunk and what a cleanup writes for it.
    private static let polishEndings: [(spoken: String, written: String)] = [
        ("", "."),
        ("no", "."), ("prawda", "?"), ("wiesz", "."),
        ("bo liczba zgłoszeń wzrosła o piętnaście procent", ", bo liczba zgłoszeń wzrosła o 15%."),
        ("a licencja kosztuje dwieście złotych", ", a licencja kosztuje 200 zł."),
        ("najpóźniej do piętnastego marca", ", najpóźniej do 15 marca."),
        ("a samo spotkanie potrwa półtorej godziny", ", a samo spotkanie potrwa 1,5 godziny."),
        ("i ma to pięćdziesiąt procent szans", ", i ma to 50% szans."),
        ("daj znać okay", ", daj znać, OK?"),
    ]
    private static let englishEndings: [(spoken: String, written: String)] = [
        ("", "."),
        ("right", "."), ("yeah", "."),
        (
            "because the number of tickets went up by fifteen percent",
            ", because the number of tickets went up by 15%."
        ),
        ("and the invoice is two hundred dollars", ", and the invoice is $200."),
        ("so let me know if that works for you okay", ". So let me know if that works for you, OK?"),
        ("and we will finish before the fifteenth of march", ", and we'll finish before the 15th of March."),
        ("and he cannot join", ", and he can't join."),
        ("and she will not join", ", and she won't join."),
    ]

    private func chunks(
        _ parts: [(spoken: String, written: String)], _ endings: [(spoken: String, written: String)]
    ) -> [(spoken: String, written: String)] {
        var made: [(spoken: String, written: String)] = []
        for count in 1...parts.count {
            for repeats in 1...2 {
                let used = Array(repeating: Array(parts.prefix(count)), count: repeats).flatMap { $0 }
                for ending in endings {
                    let spoken = (used.map(\.spoken) + [ending.spoken]).joined(separator: " ")
                        .trimmingCharacters(in: .whitespaces)
                    let body = used.map(\.written).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
                    let words = FormatterGuard.words(in: spoken)
                    if (5...60).contains(words) { made.append((spoken, body + ending.written)) }
                }
            }
        }
        return made
    }

    /// Every generated chunk: the verdict is `main`'s, or the one new reason.
    @Test func everyGeneratedChunkGetsTheVerdictOfMainExceptTheNegationRule() {
        var checked = 0
        let all = chunks(Self.polishParts, Self.polishEndings) + chunks(Self.englishParts, Self.englishEndings)
        for item in all {
            for spoken in Self.variants(of: item.spoken) {
                checked += 1
                #expect(
                    FormatterGuard.check(input: spoken, output: item.written)
                        == MainGuardReference.expected(input: spoken, output: item.written),
                    "\(spoken) -> \(item.written)")
            }
        }
        print("[guard-main-comparison] \(checked) chunks")
        #expect(checked > 500)
    }

    /// The chunk as it is, with a marker clause added at the end, and with a negation before that clause.
    static func variants(of spoken: String) -> [String] {
        [
            spoken, spoken + " czekaj tak", spoken + " sorry yes", "nie " + spoken + " czekaj tak",
            "we do not " + spoken + " sorry yes", spoken + " nie czekaj tak", spoken + " no wait yes",
        ]
    }
}
