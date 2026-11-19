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
        (["jeden"], 1), (["jedno"], 1), (["jedna"], 1), (["jednego"], 1), (["zero"], 0),
        (["dwadzieścia", "jeden"], 21), (["jeden", "tysiąc"], 1000),
        (["dwusetnego"], 200), (["trzechsetny"], 300), (["piątego"], 5), (["czwartej"], 4),
        (["piątą"], 5), (["trzeciego"], 3), (["drugim"], 2), (["pierwszy"], 1),
        (["one", "hundred", "and", "five"], 105), (["a", "hundred"], 100), (["fifteen", "hundred"], 1500),
        (["hundred"], 100), (["thousand"], 1000), (["a", "thousand"], 1000), (["zero"], 0),
        (["two", "thousand", "and", "five"], 2005),
    ])
    func numberWordsHaveTheirValue(words: [String], value: Int) {
        #expect(NumberWords.value(of: words) == value)
    }

    @Test(arguments: [
        ["ulica"], ["dwa", "trzy"], ["dwadzieścia", "dwanaście"], ["thousand", "thousand"], ["stolik"],
        ["pięć", "dwadzieścia"], [],
        // Ordinary words that start with a number stem.
        ["piątek"], ["czwartek"], ["piętro"], ["piętrze"], ["piękny"], ["trzeba"], ["trzymaj"], ["jednak"],
        ["jednostka"], ["dworzec"], ["dwór"], ["sześcian"], ["czterolatek"], ["pierwiastek"],
        ["sto", "piątek"], ["tysiąc", "dworców"], ["dwadzieścia", "trzeba"], ["and"], ["a"], ["a", "five"],
        ["one", "and", "five"], ["hundred", "and"], ["five", "and"], ["zero", "five"],
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
        // A second marker word after the correction (an apology, a hedge, an elaboration) must not move the
        // protected replacement: the final version is still the words after the FIRST marker.
        ("zamów dwie pizze nie czekaj trzy pizze jednak bez cebuli", "Zamów dwie pizze bez cebuli."),
        ("zamów dwie pizze nie czekaj trzy pizze przepraszam", "Zamów dwie pizze."),
        ("order two pizzas no wait three pizzas sorry", "Order two pizzas."),
        (
            "the meeting is at ten I mean eleven sorry for the late notice",
            "The meeting is at ten for the late notice."
        ),
        (
            "spotkanie jest o dziesiątej nie czekaj o jedenastej właściwie w sali konferencyjnej",
            "Spotkanie jest o dziesiątej w sali konferencyjnej."
        ),
        ("spotkajmy się we wtorek nie czekaj w środę jednak", "Spotkajmy się we wtorek."),
        ("book the dentist for monday no wait tuesday actually", "Book the dentist for Monday."),
        (
            "potrzebujemy pięćdziesięciu sztuk przepraszam sześćdziesięciu sztuk przepraszam",
            "Potrzebujemy 50 sztuk."
        ),
        ("we need fifty units sorry sixty units wait", "We need 50 units."),
        ("zamów dwie pizze nie czekaj trzy pizze to znaczy dużych", "Zamów dwie pizze dużych."),
        // Number words of another value are not near forms ("sześćset" for "sześćdziesiąt").
        ("budżet to sześćset złotych nie czekaj sześćdziesiąt złotych", "Budżet to sześćset złotych."),
        ("we need eighteen units sorry eighty units", "We need eighteen units."),
        ("we need seventy units sorry seventeen units", "We need seventy units."),
        ("zamów cztery kartony nie czekaj czternaście kartonów", "Zamów cztery kartony."),
        ("zamów trzy kartony nie czekaj trzynaście kartonów", "Zamów trzy kartony."),
        ("spotkanie o dziewiątej nie czekaj o dziewiętnastej", "Spotkanie o dziewiątej."),
        ("zamów siedemset sztuk przepraszam siedemdziesiąt sztuk", "Zamów siedemset sztuk."),
        ("buy seven boxes sorry seventeen boxes", "Buy seven boxes."),
        // A marker that is not on the list ("no", "a nie", "or rather", "znaczy", "nie nie") must not let the
        // final version be dropped for free: every chunk of five words or more is derived from the input.
        ("the deadline is the twelfth no the thirteenth of March", "The deadline is the twelfth of March."),
        ("the deadline is the twelfth no the thirteenth of March", "The deadline is the 12th of March."),
        (
            "spotkanie jest o dziesiątej a nie o jedenastej w sali konferencyjnej na drugim piętrze",
            "Spotkanie jest o dziesiątej w sali konferencyjnej na drugim piętrze."
        ),
        (
            "the meeting is at ten or rather eleven in the main room on the second floor",
            "The meeting is at ten in the main room on the second floor."
        ),
        (
            "zamów dwie pizze znaczy trzy pizze z szynką i dwie cole",
            "Zamów dwie pizze z szynką i dwie cole."
        ),
        (
            "spotkajmy się we wtorek nie nie w środę o piętnastej w biurze",
            "Spotkajmy się we wtorek o piętnastej w biurze."
        ),
        // A weekday or a floor is not a number: the digit must not absorb it.
        ("spotkanie piątego nie czekaj w piątek", "Spotkanie w 5."),
        ("spotkanie czwartego nie czekaj w czwartek", "Spotkanie w 4."),
        ("biuro jest na drugim nie czekaj na piętrze", "Biuro jest na 5."),
        ("zamów pięć pizz nie czekaj piątek dostawa", "Zamów 5 dostawa."),
        // A number word that starts the next one is not a stutter ("pięć pięćdziesiąt" is 5,50).
        ("cena to cztery dwadzieścia nie czekaj pięć pięćdziesiąt", "Cena to 50."),
        ("the price is five fifty sorry six sixty", "The price is 60."),
        ("the train leaves at six fifteen sorry at seven seventeen", "The train leaves at 17."),
        ("spotkanie o trzeciej nie czekaj o trzy trzydzieści", "Spotkanie o 30."),
        // The replacement may not bring back the withdrawn name through a near form (a different person).
        ("wyślij to do Kowalskiego nie czekaj do Kowalskiej", "Wyślij to do Kowalskiego."),
        ("zadzwoń do Michała nie czekaj do Michaliny", "Zadzwoń do Michała."),
        ("send it to John I mean to Johnson", "Send it to John."),
        ("zaproś Aleksandra nie czekaj Aleksandrę", "Zaproś Aleksandra."),
        ("send it to Stephen sorry to Stephanie", "Send it to Stephen."),
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

    /// The markers the speaker says in the corpus, listed here on purpose and not read from the guard, so the
    /// tests below do not depend on the code under test.
    private static let spokenMarkers: [[String]] = [
        ["czekaj"], ["jednak"], ["właściwie"], ["pomyłka"], ["przepraszam"], ["to", "znaczy"],
        ["wait"], ["actually"], ["sorry"], ["scratch", "that"], ["i", "mean"],
    ]

    /// The words the speaker said after the FIRST marker that has words after it (the final version, with
    /// anything that follows), found independently of `FormatterGuard.replacementStart`.
    private static func finalVersion(of tokens: [String]) -> [String] {
        for index in tokens.indices {
            for marker in spokenMarkers where index + marker.count < tokens.count {
                if Array(tokens[index..<(index + marker.count)]) == marker {
                    return Array(tokens[(index + marker.count)...])
                }
            }
        }
        return []
    }

    /// Whether `words` occur in `output` in order.
    private static func inOrder(_ words: [String], in output: [String]) -> Bool {
        var rest = output[...]
        for word in words {
            guard let found = rest.firstIndex(of: word) else { return false }
            rest = rest[(found + 1)...]
        }
        return true
    }

    /// The general rule behind it, without any wording from the corpus: delete one run of input words. If the
    /// guard accepts a result under the ordinary 0.6 bound (which `main` rejected as too short), every word
    /// the speaker said as the final version is still in it, in order. Run on the corpus' withdrawing cases
    /// as they are, and with an apology or a hedge appended ("... przepraszam", "... sorry", "... jednak"),
    /// which must neither move the final version nor license a deletion.
    @Test func noDeletionReachesTheFinalVersion() throws {
        var accepts = 0
        for item in try AutocorrectCorpus.load() where AutocorrectCorpus.withdrawing.contains(item.category) {
            for suffix in ["", " przepraszam", " sorry", " jednak"] {
                let raw = item.raw + suffix
                let spoken = raw.split(separator: " ").map(String.init)
                // The appended marker may go; it is no part of the final version.
                let final = Self.finalVersion(of: AutocorrectCorpus.tokens(item.raw))
                guard !final.isEmpty else { continue }
                for start in 0..<spoken.count {
                    for end in (start + 1)...spoken.count {
                        let kept = Array(spoken[..<start]) + Array(spoken[end...])
                        guard !kept.isEmpty, Double(kept.count) / Double(spoken.count) < 0.6 else { continue }
                        let output = kept.joined(separator: " ") + "."
                        guard accepted(raw, output) else { continue }
                        accepts += 1
                        #expect(
                            Self.inOrder(final, in: AutocorrectCorpus.tokens(output)),
                            "\(item.id)\(suffix): accepted deleting [\(start),\(end)) -> \(output)")
                    }
                }
            }
        }
        #expect(accepts > 0)
    }

    /// Number words of another value that look like the right one (a near form) must not stand for it: the
    /// input says the near form, the output has the corpus' correct number.
    @Test func aNearFormNumberOfAnotherValueIsNotTheFinalNumber() throws {
        let swaps = [
            "trzy": "trzynaście", "pięć": "piętnaście", "sześćdziesięciu": "sześćset", "three": "thirteen",
            "sixty": "sixteen", "thirteenth": "thirtieth", "fifty": "fifteen",
        ]
        var checked = 0
        for item in try AutocorrectCorpus.load() where AutocorrectCorpus.withdrawing.contains(item.category) {
            let spoken = item.raw.split(separator: " ").map(String.init)
            let final = Self.finalVersion(of: AutocorrectCorpus.tokens(item.raw))
            for (word, swapped) in swaps where final.contains(word) {
                let input = spoken.map { $0.lowercased() == word ? swapped : $0 }.joined(separator: " ")
                guard input != item.raw, AutocorrectCorpus.tokens(item.expected).contains(word) else { continue }
                checked += 1
                #expect(!accepted(input, item.expected), "\(item.id): \(word) -> \(swapped)")
            }
        }
        #expect(checked > 0)
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

    @Test(arguments: [
        ("zamów dwie pizze nie czekaj trzy pizze przepraszam", "Zamów trzy pizze."),
        ("zamów dwie pizze nie czekaj trzy pizze jednak bez cebuli", "Zamów trzy pizze, jednak bez cebuli."),
        ("order two pizzas no wait three pizzas sorry", "Order three pizzas."),
        ("book the dentist for monday no wait tuesday actually", "Book the dentist for Tuesday."),
        ("we need fifty units sorry sixty units actually", "We need 60 units."),
        ("we need fifty units sorry sixty units wait", "We need 60 units."),
        ("zamów dwie pizze nie czekaj trzy pizze przepraszam", "Zamów 3 pizze."),
        ("cena to cztery dwadzieścia nie czekaj pięć pięćdziesiąt", "Cena to 5,50."),
        ("cena to cztery dwadzieścia nie czekaj pięć pięćdziesiąt", "Cena to pięć pięćdziesiąt."),
        ("the price is five fifty sorry six sixty", "The price is 6,60."),
        // A contraction in the replacement is not the withdrawn word coming back.
        (
            "actually I think we should move the meeting to thursday because the client cannot join on monday",
            "I think we should move the meeting to Thursday because the client can't join on Monday."
        ),
    ])
    func aSecondMarkerAndNumberPairsKeepTheCorrectOutputAccepted(input: String, output: String) {
        #expect(accepted(input, output), "\(output)")
    }

    /// The same rejection in a chunk of 34 words of context: a long chunk gets no extra room.
    @Test func aTrailingMarkerInALongChunkStillRejectsTheLostFinalVersion() {
        let context = (0..<34).map { "kontekst\($0)" }.joined(separator: " ")
        let input = context + " zamów dwie pizze nie czekaj trzy pizze przepraszam"
        let withdrawn = (context + " Zamów dwie pizze.")
        #expect(!accepted(input, withdrawn))
        #expect(accepted(input, context + " Zamów trzy pizze."))
    }

    @Test func anUnlistedMarkerInALongChunkStillRejectsTheLostFinalVersion() {
        let context = (0..<34).map { "kontekst\($0)" }.joined(separator: " ")
        let input = context + " spotkanie jest o dziesiątej a nie o jedenastej"
        #expect(!accepted(input, context + " Spotkanie jest o dziesiątej."))
    }

    @Test func youKnowIsContentAfterLetAndIfButAFillerElsewhere() {
        let input = "send the file to Mark sorry to Steven and I will let you know"
        #expect(accepted(input, "Send the file to Steven and I will let you know."))
        #expect(!accepted(input, "Send the file to Steven and I will let."))
        // A filler "you know" in the middle may still go.
        #expect(accepted("we should you know move the meeting to monday", "We should move the meeting to Monday."))
    }

    @Test(arguments: ["yyyy", "yyyyy", "eeee", "eeeee", "erm", "eh", "mhm", "yy", "ee"])
    func aHesitationIsRemovedWhateverTheSpelling(filler: String) {
        let input = "\(filler) zamów dwie pizze nie czekaj trzy pizze z szynką \(filler)"
        #expect(accepted(input, "Zamów trzy pizze z szynką."))
        #expect(FormatterGuard.removableAllowance(input.split(separator: " ").map(String.init)) > 0)
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
        // Number words of another value are never near forms; the same value in another case is.
        for (word, other) in [
            ("sześćset", "sześćdziesiąt"), ("trzy", "trzynaście"), ("cztery", "czternaście"),
            ("seven", "seventeen"), ("eighteen", "eighty"), ("dziewiątej", "dziewiętnastej"),
        ] {
            #expect(!FormatterGuard.isNearForm(word, other), "\(word) \(other)")
        }
        #expect(FormatterGuard.isNearForm("piętnastej", "piętnastego"))
    }
}
