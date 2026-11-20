import Foundation
import Testing

@testable import DictationPlugin

/// Runs `GuardProbeTable` (every probe of review rounds 1 to 3) against `FormatterGuard`, and the round 3 families:
/// an unsaid word in the replacement, a dropped marker, and ordinary chunks without a marker. All text is invented.
@Suite struct GuardProbeTests {
    private func accepted(_ input: String, _ output: String) -> Bool {
        if case .accepted = FormatterGuard.check(input: input, output: output) { return true }
        return false
    }

    /// Correct cleanups the guard turns into the raw text. Each is a documented limit (ADR 0010, "What the guard
    /// still cannot see"); the test fails when one starts to be accepted, so this list stays true.
    private static let safeFallbacks: Set<String> = [
        // A chained correction, a content "właściwie" or "sorry" that protects the words after it, "półtora",
        // a currency sign, "2 tys.", a year, "2-go", a name's recognition spelling as the last word.
        "H7a", "H8e", "N9", "N10", "N22", "N26", "N29", "N37", "N39", "F3", "F16",
        // A content marker (actually, sorry, jednak, to znaczy, właściwie) in a long chunk: the chunk is checked
        // as a correction, so any other dropped word falls back. A year spoken as two pairs ("twenty twenty
        // six"), a recognition error in the very last word.
        "A16", "A17", "A24", "A27", "A28", "A31", "A32",
    ]

    /// Texts that lose the final version or other content and that the guard still accepts. Each is a documented
    /// limit; `main` accepts them too. The test fails when one starts to be rejected.
    private static let knownLimits: Set<String> = [
        // A long chunk: the edit budget (a tenth of the words) absorbs a spoken correction whose number words
        // become digits, a single dropped "nie", a digit of another value, and the words before a content marker.
        "B10", "B11", "B12", "B13",
    ]

    @Test func everyProbeOfRoundsOneAndTwo() {
        for row in GuardProbeTable.rounds12 {
            let result = accepted(row.input, row.output)
            if row.ok {
                #expect(result == !Self.safeFallbacks.contains(row.id), "\(row.id): \(row.output)")
            } else {
                #expect(!result, "\(row.id) is a hole: \(row.output)")
            }
        }
    }

    @Test func everyProbeOfRoundThree() {
        for row in GuardProbeTable.round3 {
            let result = accepted(row.input, row.output)
            if row.ok {
                #expect(result == !Self.safeFallbacks.contains(row.id), "\(row.id): \(row.output)")
            } else {
                #expect(result == Self.knownLimits.contains(row.id), "\(row.id): \(row.output)")
            }
        }
    }

    // MARK: A word the speaker never said, in the replacement

    @Test(arguments: [
        ("wyślij raport do Tomka nie czekaj do Adama jeszcze dziś", "Wyślij raport do Tomasza jeszcze dziś."),
        ("send the report to Kate no wait to Mark today", "Send the report to Katie today."),
        ("napisz do Oli nie czekaj do Ewy w sprawie urlopu", "Napisz do Olki w sprawie urlopu."),
        ("wyślij raport do Kasi nie czekaj do Marka jeszcze dziś", "Wyślij raport do Tomka jeszcze dziś."),
        ("wyślij raport do Kasi nie czekaj do Marka jeszcze dziś", "Wyślij raport do Kaśki jeszcze dziś."),
        ("zamów pizzę z szynką nie czekaj z pieczarkami i colę", "Zamów pizzę z ananasem i colę."),
        ("send it to Mark no wait to Steven and Paul today", "Send it to Zebra and Paul today."),
    ])
    func anUnsaidWordDoesNotStandForTheFinalVersion(input: String, output: String) {
        #expect(!accepted(input, output), "\(output)")
    }

    @Test(arguments: [
        // A close spelling (a recognition fix) and a contraction are allowed in the replacement.
        ("send it to Mark no wait to Steven and Paul today", "Send it to Stephen and Paul today."),
        (
            "actually I think we should move the meeting to thursday because the client cannot join on monday",
            "I think we should move the meeting to Thursday because the client can't join on Monday."
        ),
    ])
    func aCloseSpellingOrAContractionStaysAccepted(input: String, output: String) {
        #expect(accepted(input, output), "\(output)")
    }

    /// Replaces each word of the final version, one at a time, by a word nobody said: always rejected.
    @Test func swappingAFinalVersionWordForAnInventedOneIsRejected() throws {
        var checked = 0
        for item in try AutocorrectCorpus.load() where AutocorrectCorpus.withdrawing.contains(item.category) {
            let expected = item.expected.split(separator: " ").map(String.init)
            let final = Set(Self.tail(of: AutocorrectCorpus.tokens(item.raw)))
            for (index, word) in expected.enumerated() {
                let bare = AutocorrectCorpus.tokens(word).first ?? ""
                guard final.contains(bare), bare.count >= 4, !bare.contains(where: \.isNumber) else { continue }
                var swapped = expected
                swapped[index] = "Zebrafort" + (word.last.map { ".!?,".contains($0) ? String($0) : "" } ?? "")
                checked += 1
                #expect(!accepted(item.raw, swapped.joined(separator: " ")), "\(item.id): \(bare)")
            }
        }
        #expect(checked > 20)
    }

    private static func tail(of tokens: [String]) -> [String] {
        let markers: [[String]] = [
            ["czekaj"], ["jednak"], ["właściwie"], ["pomyłka"], ["przepraszam"], ["to", "znaczy"], ["wait"],
            ["actually"], ["sorry"], ["scratch", "that"], ["i", "mean"],
        ]
        for index in tokens.indices {
            for marker in markers where index + marker.count < tokens.count {
                if Array(tokens[index..<(index + marker.count)]) == marker {
                    return Array(tokens[(index + marker.count)...])
                }
            }
        }
        return []
    }

    // MARK: The marker was dropped and both versions stayed

    /// Answers the saved real-model runs gave on the corpus (invented sentences): the marker word is gone, both
    /// versions are in the text and nothing says which one is final ("na pizzę albo na sushi"; in the first,
    /// "we wtorek, a nie w środę", the meaning is inverted).
    @Test(arguments: [
        ("spotkajmy się we wtorek a nie czekaj w środę", "Spotkajmy się we wtorek, a nie w środę."),
        ("pójdziemy na pizzę albo jednak na sushi", "Pójdziemy na pizzę albo na sushi."),
        (
            "przełóżmy spotkanie na piątek albo jednak na poniedziałek",
            "Przełóżmy spotkanie na piątek albo na poniedziałek."
        ),
        ("kupimy czerwoną sofę albo jednak szarą sofę", "Kupimy czerwoną sofę albo szarą sofę."),
        (
            "użyjemy chmury albo jednak zostaniemy przy własnym serwerze",
            "Użyjemy chmury albo zostaniemy przy własnym serwerze."
        ),
        ("wyślę to mailem albo jednak zadzwonię do klienta", "Wyślę to mailem albo zadzwonię do klienta."),
    ])
    func aDroppedMarkerWithTheWithdrawnVersionKeptIsRejected(input: String, output: String) {
        #expect(!accepted(input, output), "\(output)")
    }

    @Test(arguments: [
        // The marker stays, so the reader can see which version is final.
        ("spotkanie z Anną nie przepraszam z Hanną w środę", "Spotkanie z Anną nie przepraszam – z Hanną w środę."),
        ("wyślę to mailem albo jednak zadzwonię do klienta", "Wyślę to mailem, albo jednak zadzwonię do klienta."),
        // The withdrawn version is gone: the ordinary correction.
        ("spotkajmy się we wtorek a nie czekaj w środę", "Spotkajmy się w środę."),
        ("kupimy czerwoną sofę albo jednak szarą sofę", "Kupimy szarą sofę."),
        ("pójdziemy na pizzę albo jednak na sushi", "Pójdziemy na sushi."),
    ])
    func aKeptMarkerOrARemovedWithdrawnVersionIsAccepted(input: String, output: String) {
        #expect(accepted(input, output), "\(output)")
    }

    // MARK: Chunks without a marker

    /// A reference copy of the checks `main` runs on a chunk: the length range and the language.
    private func mainAccepts(input: String, output: String) -> Bool {
        let output = FormatterGuard.clean(output)
        guard !output.isEmpty else { return false }
        let inputWords = FormatterGuard.words(in: input)
        let outputWords = FormatterGuard.words(in: output)
        if inputWords >= 5 {
            let ratio = Double(outputWords) / Double(inputWords)
            if !FormatterGuard.lengthRange.contains(ratio) { return false }
        } else if outputWords > inputWords + 3 {
            return false
        }
        let before = Language.dominant(in: input)
        let after = Language.dominant(in: output)
        return !(before != .unknown && after != .unknown && before != after)
    }

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
        ("limit wynosi do pięciuset to znaczy do tysiąca złotych", ", limit wynosi do 1000 złotych."),
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

    /// A chunk of 5 to 60 words with no marker and no correction: whatever `main` accepts, the guard accepts.
    /// (A clock time spoken as "wpół do ósmej" and written "7:30" is the one ordinary rewrite that falls back in
    /// a short chunk; it is listed as a limit and not generated here.)
    @Test func aChunkWithoutAMarkerIsAcceptedWheneverMainAcceptsIt() {
        var checked = 0
        let all = chunks(Self.polishParts, Self.polishEndings) + chunks(Self.englishParts, Self.englishEndings)
        for item in all {
            guard mainAccepts(input: item.spoken, output: item.written) else { continue }
            checked += 1
            #expect(accepted(item.spoken, item.written), "\(item.spoken) -> \(item.written)")
        }
        #expect(checked > 150)
    }

    /// Contractions are merged at no cost, however many a long chunk holds.
    @Test func manyContractionsInALongChunkAreAccepted() {
        let spoken = Self.englishParts.map(\.spoken).joined(separator: " ")
        let written = Self.englishParts.map(\.written).joined(separator: " ") + "."
        #expect(accepted(spoken, written))
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

    @Test(arguments: ["tysiąca", "dwóm", "stoma", "dwom", "tysięcy"])
    func moreNumberForms(word: String) {
        #expect(NumberWords.value(of: [word]) != nil)
    }

    @Test func aWholeWordThatStartsTheNextIsNotAStutter() {
        #expect(!accepted("zamów dwie pizze nie czekaj pizze pizzerii obok", "Zamów pizzerii obok."))
        #expect(
            accepted("pro prosiłbym o zaakceptowanie tej zmiany dzisiaj", "Proszę o zaakceptowanie tej zmiany dzisiaj.")
        )
    }
}
