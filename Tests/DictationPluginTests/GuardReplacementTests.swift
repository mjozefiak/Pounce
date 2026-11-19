import Foundation
import Testing

@testable import DictationPlugin

/// ADR 0010, round 2: the guard must never accept "the withdrawn version stayed, the final one is lost"
/// (the ADR 0005 failure), which `main` rejected as too short. These tests are written from the rule, not from
/// the corpus' wording: every output that deletes a word the speaker said AFTER the last retraction marker is
/// rejected, whatever the words are.
@Suite struct GuardReplacementTests {
    private func accepted(_ input: String, _ output: String) -> Bool {
        FormatterGuard.check(input: input, output: output) == .accepted(FormatterGuard.clean(output))
    }

    // MARK: Number words

    @Test(arguments: [
        (["sześćdziesięciu"], 60), (["pięćdziesięciu"], 50), (["jedenastej"], 11), (["dziesiątej"], 10),
        (["dwunastego"], 12), (["trzynastego"], 13), (["szóstej"], 6), (["czterdzieści"], 40),
        (["dwadzieścia", "pięć", "tysięcy"], 25000), (["osiemnaście", "tysięcy"], 18000),
        (["sto", "dwadzieścia", "trzy"], 123), (["dwa", "tysiące", "dwadzieścia", "pięć"], 2025),
        (["sixty"], 60), (["fifty"], 50), (["twenty", "five", "thousand"], 25000),
        (["two", "hundred", "thirty"], 230), (["thirteenth"], 13), (["tenth"], 10), (["eleven"], 11),
        (["tysiąc"], 1000), (["trzysta"], 300),
    ])
    func numberWordsHaveTheirValue(words: [String], value: Int) {
        #expect(NumberWords.value(of: words) == value)
    }

    @Test(arguments: [
        ["ulica"], ["dwa", "trzy"], ["dwadzieścia", "dwanaście"], ["thousand", "thousand"], ["stolik"],
        ["pięć", "dwadzieścia"], ["hundred"], [],
    ])
    func notNumbersGiveNil(words: [String]) {
        #expect(NumberWords.value(of: words) == nil)
    }

    // MARK: The withdrawn version stayed, the final one is lost

    @Test(arguments: [
        (
            "spotkanie jest o dziesiątej nie to znaczy o jedenastej w sali konferencyjnej",
            "Spotkanie jest o dziesiątej w sali konferencyjnej."
        ),
        (
            "spotkanie jest o dziesiątej nie to znaczy o jedenastej w sali konferencyjnej",
            "Spotkanie jest o 10."
        ),
        (
            "spotkanie jest o dziesiątej nie to znaczy o jedenastej w sali konferencyjnej",
            "Spotkanie jest o 10 w sali konferencyjnej."
        ),
        ("potrzebujemy pięćdziesięciu sztuk przepraszam sześćdziesięciu sztuk", "Potrzebujemy 50 sztuk."),
        (
            "potrzebujemy pięćdziesięciu sztuk przepraszam sześćdziesięciu sztuk",
            "Potrzebujemy pięćdziesięciu sztuk."
        ),
        ("we need fifty units sorry sixty units", "We need 50 units."),
        ("we need fifty units sorry sixty units", "We need fifty units."),
        ("the meeting is at ten I mean eleven in the main room", "The meeting is at 10."),
        ("the meeting is at ten I mean eleven in the main room", "The meeting is at ten in the main room."),
        ("the meeting is at ten I mean eleven in the main room", "The meeting is at 10 in the main room."),
        ("termin mija dwunastego a właściwie trzynastego marca", "Termin mija 12 marca."),
        ("adres to ulica Lipowa dwanaście pomyłka ulica Lipowa dwadzieścia", "Adres to ulica Lipowa 12."),
        ("pociąg odjeżdża o szóstej trzydzieści to znaczy o szóstej czterdzieści", "Pociąg odjeżdża o 6:30."),
        ("zamów dwie pizze nie czekaj trzy pizze z szynką", "Zamów 2 pizze z szynką."),
        ("zamów dwie pizze nie czekaj trzy pizze z szynką", "Zamów dwie pizze z szynką."),
        ("wdrożymy to dziś na staging nie to znaczy na produkcję", "Wdrożymy to dziś na staging."),
        ("we deploy tonight to staging I mean to production", "We deploy tonight to staging."),
        ("spotkajmy się we wtorek a nie czekaj w środę", "Spotkajmy się we wtorek."),
        ("wyślę to mailem albo jednak zadzwonię do klienta", "Wyślę to mailem."),
        ("kupimy czerwoną sofę albo jednak szarą sofę", "Kupimy czerwoną sofę."),
        ("kupimy czerwoną sofę albo jednak szarą sofę", "Kupimy sofę."),
    ])
    func keptWithdrawnAndLostFinalIsRejected(input: String, output: String) {
        #expect(!accepted(input, output), "\(output)")
    }

    /// Every corpus `known_bad` that keeps the withdrawn version and loses the final one is rejected. A
    /// `known_bad` that keeps BOTH versions (marker words included) is not the ADR 0005 failure: the guard may
    /// accept it, nothing is lost, and the real-model report counts it separately. These are the only ones.
    @Test func everyCorpusKnownBadThatLosesTheFinalVersionIsRejected() throws {
        let bothVersionsKept: Set<String> = [
            "pl-ret-9", "pl-cor-1", "en-cor-1",
        ]
        var documented = 0
        for item in try AutocorrectCorpus.load() {
            for bad in item.knownBad ?? [] {
                let lostFinal = !item.mustKeep.allSatisfy {
                    AutocorrectCorpus.holds(Set(AutocorrectCorpus.tokens(bad)), $0)
                }
                if lostFinal {
                    #expect(!accepted(item.raw, bad), "\(item.id): \(bad)")
                } else {
                    #expect(bothVersionsKept.contains(item.id), "\(item.id): unexpected exception \(bad)")
                    documented += 1
                }
            }
        }
        #expect(documented == 3)
    }

    /// The general rule behind it, without any wording from the corpus: delete one run of input words. If the
    /// guard accepts a result under the ordinary 0.6 bound (which `main` rejected as too short), every word the
    /// speaker said after the last marker is still in it, in order.
    @Test func noDeletionReachesTheReplacementAfterTheLastMarker() throws {
        var accepts = 0
        for item in try AutocorrectCorpus.load() where AutocorrectCorpus.withdrawing.contains(item.category) {
            let spoken = item.raw.split(separator: " ").map(String.init)
            let tokens = AutocorrectCorpus.tokens(item.raw)
            let tail = FormatterGuard.replacementStart(tokens) ?? tokens.count
            for start in 0..<spoken.count {
                for end in (start + 1)...spoken.count {
                    let kept = Array(spoken[..<start]) + Array(spoken[end...])
                    guard !kept.isEmpty else { continue }
                    let output = kept.joined(separator: " ") + "."
                    // Only what `main` rejected as too short (ratio under 0.6) is in scope here.
                    guard Double(kept.count) / Double(spoken.count) < FormatterGuard.lengthRange.lowerBound else {
                        continue
                    }
                    if accepted(item.raw, output) {
                        accepts += 1
                        // Nothing the speaker said after the last marker is gone: the replacement is a
                        // subsequence of the output (a withdrawn word that stayed too is the "both versions
                        // kept" class, which loses nothing).
                        var rest = AutocorrectCorpus.tokens(output)[...]
                        var kept = true
                        for word in tokens[tail...] {
                            guard let found = rest.firstIndex(of: word) else {
                                kept = false
                                break
                            }
                            rest = rest[(found + 1)...]
                        }
                        #expect(kept, "\(item.id): accepted deleting [\(start),\(end)) -> \(output)")
                    }
                }
            }
        }
        #expect(accepts > 0)
    }

    // MARK: Correct results stay accepted

    @Test(arguments: [
        ("potrzebujemy pięćdziesięciu sztuk przepraszam sześćdziesięciu sztuk", "Potrzebujemy 60 sztuk."),
        ("potrzebujemy pięćdziesięciu sztuk przepraszam sześćdziesięciu sztuk", "Potrzebujemy sześćdziesięciu sztuk."),
        ("pociąg odjeżdża o szóstej trzydzieści to znaczy o szóstej czterdzieści", "Pociąg odjeżdża o 6:40."),
        (
            "budżet wynosi osiemnaście tysięcy to znaczy dwadzieścia pięć tysięcy złotych",
            "Budżet wynosi 25 000 złotych."
        ),
        (
            "budżet wynosi osiemnaście tysięcy to znaczy dwadzieścia pięć tysięcy złotych",
            "Budżet wynosi dwadzieścia pięć tysięcy złotych."
        ),
        ("the meeting is at ten I mean eleven in the main room", "The meeting is at 11 in the main room."),
        ("we need fifty units sorry sixty units", "We need 60 units."),
        ("termin mija dwunastego a właściwie trzynastego marca", "Termin mija 13 marca."),
        ("zamów dwie pizze nie czekaj trzy pizze z szynką", "Zamów 3 pizze z szynką."),
        ("send it to Mark no wait to Steven", "Send it to Steven."),
        ("spotkajmy się we wtorek a nie czekaj w środę o piętnastej", "Spotkajmy się w środę o 15:00."),
        ("spotkajmy się we wtorek a nie czekaj w środę o piętnastej", "Spotkajmy się w środę o 15."),
        // Ends on a filler or a marker word: the last word of the input is not what the output must end on.
        ("zamów dwie pizze nie czekaj trzy pizze yyy", "Zamów trzy pizze."),
        ("order two pizzas no wait three pizzas um", "Order three pizzas."),
        // A near form of the last word (inflection or recognition fix).
        ("wyślij raport do Kasi nie czekaj do Marka jeszcze dziś", "Wyślij raport do Marka jeszcze dziś."),
    ])
    func correctRetractionsStayAccepted(input: String, output: String) {
        #expect(accepted(input, output), "\(output)")
    }

    @Test func aDigitWithAnotherValueIsNotAbsorbed() {
        // 70 is not "sześćdziesięciu": the digit is an unrelated token in the replacement.
        #expect(
            !accepted("potrzebujemy pięćdziesięciu sztuk przepraszam sześćdziesięciu sztuk", "Potrzebujemy 70 sztuk."))
        #expect(
            !accepted(
                "pociąg odjeżdża o szóstej trzydzieści to znaczy o szóstej czterdzieści", "Pociąg odjeżdża o 6:45."))
    }

    // MARK: Long chunks (a marker or filler must not license a deletion of half the chunk)

    private let filler =
        "ostatnio dużo pracujemy nad nowym modułem raportów i musimy dopracować wiele drobnych szczegółów"

    private func longChunk(prefix: String, middle: String, suffix: String) -> String {
        [prefix, middle, suffix].filter { !$0.isEmpty }.joined(separator: " ")
    }

    @Test func oneFillerDoesNotLowerTheBoundOfALongChunk() {
        let words = (0..<45).map { "słowo\($0)" }
        let input = "yyy " + words.joined(separator: " ")
        // The last 18 words alone.
        let output = words.suffix(18).joined(separator: " ") + "."
        #expect(FormatterGuard.check(input: input, output: output) == .rejected(.tooShort))
    }

    @Test func aMidChunkDeletionOfTwelveWordsWithOneFillerIsRejected() {
        let words = (0..<25).map { "termin\($0)" }
        let input = "yyy " + words.joined(separator: " ")
        // Twelve words in the middle deleted: the filler explains one word, nothing explains the other twelve.
        let output = (Array(words[..<8]) + Array(words[20...])).joined(separator: " ") + "."
        #expect(FormatterGuard.check(input: input, output: output) == .rejected(.tooShort))
        let twelve = (Array(words[..<6]) + Array(words[18...])).joined(separator: " ") + "."
        #expect(FormatterGuard.check(input: input, output: twelve) == .rejected(.tooShort))
    }

    @Test func aMarkerUsedAsContentDoesNotLicenseDeletingTheWordsBeforeIt() {
        let before = (0..<15).map { "przed\($0)" }
        let after = (0..<22).map { "po\($0)" }
        let input = (before + ["jednak"] + after).joined(separator: " ")
        // The 15 words before "jednak" and the marker deleted: more than the span cap, and unanchored.
        let output = after.joined(separator: " ") + "."
        #expect(!accepted(input, output))
    }

    @Test func aCorrectRetractionInALongChunkIsAccepted() {
        let before = (0..<20).map { "poprzednie\($0)" }
        let after = (0..<22).map { "kolejne\($0)" }
        let retracted = "wyślemy to w poniedziałek rano"
        let input =
            (before + retracted.split(separator: " ").map(String.init) + ["nie", "czekaj", "wyślemy", "to"]
            + ["we", "wtorek"] + after).joined(separator: " ")
        let output = (before + ["wyślemy", "to", "we", "wtorek"] + after).joined(separator: " ") + "."
        #expect(accepted(input, output))
    }

    @Test func aNegatedImperativeAfterAMarkerWordKeepsItsWords() {
        // "nie czekaj" as content: the output keeps every word, so it passes; dropping them does not.
        let input = "napisz Piotrkowi nie czekaj na mnie z kolacją"
        #expect(accepted(input, "Napisz Piotrkowi: nie czekaj na mnie z kolacją."))
        #expect(!accepted(input, "Napisz Piotrkowi."))
    }

    // MARK: Reasons

    @Test func anOutputThatEndsElsewhereIsEndChanged() {
        #expect(
            FormatterGuard.check(
                input: "pójdziemy na pizzę albo jednak na sushi", output: "Pójdziemy na pizzę.")
                == .rejected(.endChanged))
    }

    @Test func nearFormRule() {
        #expect(FormatterGuard.isNearForm("marka", "mark"))
        #expect(FormatterGuard.isNearForm("hanną", "hanna"))
        #expect(!FormatterGuard.isNearForm("nowak", "nowicki"))
        #expect(!FormatterGuard.isNearForm("do", "dla"))
    }
}
