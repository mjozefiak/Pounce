import Foundation
import Testing

@testable import DictationPlugin

/// A faithful copy of the check `main` ran on every chunk before the self-correction work: the length range and
/// the language. A chunk without a retraction marker must get exactly this verdict from `FormatterGuard`.
enum MainGuardReference {
    static func accepts(input: String, output rawOutput: String) -> Bool {
        let output = FormatterGuard.clean(rawOutput)
        guard !output.isEmpty else { return false }
        let inputWords = FormatterGuard.words(in: input)
        let outputWords = FormatterGuard.words(in: output)
        if inputWords >= 5 {
            let ratio = Double(outputWords) / Double(inputWords)
            if ratio > FormatterGuard.lengthRange.upperBound || ratio < FormatterGuard.lengthRange.lowerBound {
                return false
            }
        } else if outputWords > inputWords + 3 {
            return false
        }
        let before = Language.dominant(in: input)
        let after = Language.dominant(in: output)
        return !(before != .unknown && after != .unknown && before != after)
    }
}

/// Runs `GuardProbeTable` (every probe of review rounds 1 to 4, all invented) against `FormatterGuard`, and
/// compares the chunks without a marker with `main`.
@Suite struct GuardProbeTests {
    private func accepted(_ input: String, _ output: String) -> Bool {
        if case .accepted = FormatterGuard.check(input: input, output: output) { return true }
        return false
    }

    private func hasMarker(_ input: String) -> Bool {
        FormatterGuard.selfCorrection(in: FormatterGuard.tokens(input)) != nil
    }

    private static let table =
        GuardProbeTable.rounds12 + GuardProbeTable.round3 + GuardProbeTable.round4
        + GuardProbeTable.round5

    /// Correct cleanups that the guard turns into the raw text (fail-safe). Each is a documented limit of the
    /// marker rule (ADR 0010, "What the guard rejects although the result is right"); the test fails when one is
    /// accepted or a new one appears, so the list and its count stay true.
    static let falseAlarms: Set<String> = [
        "H7a", "H8e", "N9", "N10", "N11", "N18", "N20", "N22", "N26", "N29", "N32", "N34", "N37", "N39", "F3", "F8",
        "F15", "F16", "F19", "F20", "F23", "F26", "A24", "A27", "A28", "A31", "A32", "VS11", "VP6", "VM10",
    ]

    /// Texts that lose the final version or other content, have NO marker, and that `main` accepts too (ADR 0010,
    /// "Limits shared with main"). The test fails when one starts to be rejected.
    static let limitsSharedWithMain: Set<String> = [
        "H6a", "H6b", "H6c", "H6d", "H8f", "H10a", "H10b", "B6", "B7", "B8", "B9", "B10", "B11", "B12", "B14", "VE4",
        "VE5", "VC1", "VC2", "VD1", "VD2",
    ]

    @Test func noProbeWithAMarkerIsAHole() {
        var checked = 0
        for row in Self.table where !row.ok && hasMarker(row.input) {
            checked += 1
            #expect(!accepted(row.input, row.output), "\(row.id) is a hole: \(row.output)")
        }
        #expect(checked > 100)
    }

    @Test func aProbeWithoutAMarkerGetsTheVerdictOfMain() {
        var accepting: Set<String> = []
        for row in Self.table where !hasMarker(row.input) {
            #expect(
                accepted(row.input, row.output) == MainGuardReference.accepts(input: row.input, output: row.output),
                "\(row.id)")
            if !row.ok, accepted(row.input, row.output) { accepting.insert(row.id) }
        }
        #expect(accepting == Self.limitsSharedWithMain)
    }

    @Test func correctCleanupsAreAcceptedExceptTheListedFalseAlarms() {
        var fallbacks: Set<String> = []
        var total = 0
        for row in Self.table where row.ok {
            total += 1
            if !accepted(row.input, row.output) { fallbacks.insert(row.id) }
        }
        #expect(fallbacks == Self.falseAlarms, "\(fallbacks.symmetricDifference(Self.falseAlarms).sorted())")
        print("[guard-probes] correct cleanups \(total), false alarms \(fallbacks.count)")
    }

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

    /// A chunk of 5 to 60 words with no marker: the verdict is the one `main` gives, accepted or rejected.
    @Test func aChunkWithoutAMarkerGetsTheVerdictOfMain() {
        var checked = 0
        let all = chunks(Self.polishParts, Self.polishEndings) + chunks(Self.englishParts, Self.englishEndings)
        for item in all {
            #expect(!hasMarker(item.spoken))
            checked += 1
            #expect(
                accepted(item.spoken, item.written)
                    == MainGuardReference.accepts(input: item.spoken, output: item.written),
                "\(item.spoken) -> \(item.written)")
        }
        print("[guard-main-comparison] \(checked) chunks")
        #expect(checked > 100)
    }

    /// The cases the third review found that a derivation-based rule had to give up on, now simply `main`'s.
    @Test(arguments: [
        (
            "the build was kind of slow yesterday so we restarted it",
            "The build was slow yesterday, so we restarted it."
        ),
        ("no to wyślij mi ten plik jeszcze dziś", "Wyślij mi ten plik jeszcze dziś."),
        ("we will not ship it on friday", "We'll ship it on Friday."),
        ("nie wysyłaj tego klientowi przed piątkiem", "Wysyłaj to klientowi przed piątkiem."),
        ("ten bilet kosztuje dwieście euro", "Ten bilet kosztuje 200 zł."),
        ("podwyżka wyniesie piętnaście procent", "Podwyżka wyniesie 15 zł."),
    ])
    func theReportedCasesFollowMain(input: String, output: String) {
        #expect(accepted(input, output) == MainGuardReference.accepts(input: input, output: output))
    }

    /// The two ways that an ordinary rewrite becomes a contraction are read by form, not by a list of words.
    @Test(arguments: [
        ("we", "are", "we're", true), ("it", "is", "it's", true), ("they", "will", "they'll", true),
        ("do", "not", "don't", true), ("will", "not", "won't", true), ("can", "not", "can't", true),
        ("i", "am", "i'm", true), ("let", "us", "let's", true), ("we", "are", "they're", false),
        ("do", "not", "do'nt", false), ("we", "are", "were", false), ("we", "have", "we've", true),
    ])
    func contractionForms(first: String, second: String, written: String, expected: Bool) {
        #expect(FormatterGuard.isContraction(first, second, written) == expected)
    }

}
