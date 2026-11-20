import Foundation
import Testing

@testable import DictationPlugin

/// The one rule the guard adds to `main`'s checks (owner decision 2026-11-20, variant A, ADR 0010): a chunk with
/// a spoken retraction marker and a negation anywhere before the FIRST marker is not cleaned; the raw text is
/// pasted. Every text is invented.
@Suite struct NegationRuleTests {
    @Test(arguments: [
        // Polish: every negation of the list, far from the marker and next to it.
        "nie przyjdę jutro czekaj przyjdę jutro",
        "nigdy nie płać gotówką czekaj płać kartą",
        "nic nie kupuj teraz jednak kupuj",
        "nikt przyjdzie właściwie wszyscy przyjdą",
        "żaden z nich nie wyśle pomyłka obaj wyślą",
        "żadna oferta przepraszam dwie oferty",
        "żadne pieniądze to znaczy wszystkie pieniądze",
        "kup herbatę bez cukru czekaj z cukrem",
        "ani kawa ani herbata czekaj obie",
        // English.
        "do not send it yet sorry send it now",
        "this is not ready actually it is ready",
        "never send it to them wait send it",
        "none of them scratch that all of them",
        "nothing is ready I mean everything is ready",
        "nobody called sorry somebody called",
        "neither of them came actually both came",
        "nor did he call sorry he called",
        "go without him wait with him",
        "he cannot come actually he can come",
    ])
    func aNegationBeforeTheFirstMarkerIsFound(input: String) {
        #expect(FormatterGuard.negationBeforeMarker(in: input), "\(input)")
    }

    @Test(arguments: [
        "don't send it yet sorry send it now", "we didn’t ship it actually we did", "she couldn't come wait she could",
        "i won't go sorry i will", "they aren't ready actually they are",
        // The recogniser left the apostrophe out.
        "dont send it yet sorry send it", "we cant ship it actually we can", "he wont call sorry he will",
        "they havent paid wait they have", "it isnt ready actually it is",
    ])
    func aContractionIsANegation(input: String) {
        #expect(FormatterGuard.negationBeforeMarker(in: input), "\(input)")
    }

    @Test(arguments: [
        "NIE PRZYJDĘ JUTRO CZEKAJ PRZYJDĘ JUTRO", "Nie przyjdę jutro, czekaj, przyjdę jutro.",
        "Do NOT send it yet, Sorry, send it now!", "nie, nie przyjdę jutro... czekaj; przyjdę jutro?",
        "  nie\tprzyjdę   jutro\nczekaj przyjdę jutro  ",
    ])
    func caseAndPunctuationDoNotMatter(input: String) {
        #expect(FormatterGuard.negationBeforeMarker(in: input), "\(input)")
    }

    @Test(arguments: [
        // A negation AFTER the marker is the replacement: it blocks nothing.
        "przyjdę w piątek czekaj nie przyjdę w piątek", "it is ready actually it is not ready",
        "wyślij to w piątek czekaj nie w piątek tylko w sobotę", "send it sorry do not send it",
        // The "nie" or "no" of the marker itself is not a negation before it.
        "zamów dwie pizze nie czekaj trzy pizze", "o dziesiątej nie to znaczy o jedenastej",
        "book the dentist for monday no wait tuesday", "nie, czekaj, w środę",
        // No marker: the rule does not apply, however many negations there are.
        "nie przyjdę jutro bo nie mogę", "we do not ship it on friday", "nigdy nie mów nikomu nic",
        // Words that only end like a contraction, or that contain a negation.
        "i want the moment to last actually it is fine", "student wants a lunch sorry a dinner",
        "nicość to pojęcie czekaj inne pojęcie", "another note wait a minute",
        // The Polish particle "no" in a filler, and a marker with nothing in front of it.
        "no więc spotkanie jest o dziesiątej nie czekaj o jedenastej", "no to wyślij czekaj wyślij jutro",
        "czekaj nie przyjdę", "",
    ])
    func noNegationBeforeTheFirstMarkerIsNotFound(input: String) {
        #expect(!FormatterGuard.negationBeforeMarker(in: input), "\(input)")
    }

    @Test func theEnglishNoIsANegationOnlyOutsideAPolishChunk() {
        #expect(FormatterGuard.negationBeforeMarker(in: "there is no budget for it sorry there is some budget"))
        #expect(
            !FormatterGuard.negationBeforeMarker(in: "no więc to jest dla nas ważne i to jest pilne czekaj później"))
    }

    @Test func onlyTheFirstMarkerCounts() {
        // The negation stands between two markers: it is before the second, not before the first.
        #expect(!FormatterGuard.negationBeforeMarker(in: "wyślij to czekaj nie wysyłaj tego jednak wyślij"))
        #expect(FormatterGuard.negationBeforeMarker(in: "nie wysyłaj tego czekaj wyślij jednak nie wysyłaj"))
    }

    @Test func aChunkTheMainChecksAcceptIsTurnedBackToTheRawText() {
        let input = "nie wyślę tego dzisiaj do klienta czekaj wyślę to jutro rano"
        let inverted = "Wyślę tego dzisiaj do klienta, wyślę to jutro rano."
        let kept = "Nie wyślę tego dzisiaj do klienta, wyślę to jutro rano."
        #expect(FormatterGuard.check(input: input, output: inverted) == .rejected(.negationBeforeMarker))
        #expect(FormatterGuard.check(input: input, output: kept) == .rejected(.negationBeforeMarker))
        // A chunk without a negation before the marker keeps the verdict of main.
        let plain = "wyślij to dzisiaj do klienta czekaj wyślij to jutro rano"
        let cleaned = "Wyślij to dzisiaj do klienta, czekaj, wyślij to jutro rano."
        #expect(FormatterGuard.check(input: plain, output: cleaned) == .accepted(cleaned))
    }

    @Test func theReasonsOfMainStayFirst() {
        let input = "nie przyjdę jutro czekaj przyjdę jutro"
        #expect(FormatterGuard.check(input: input, output: "") == .rejected(.empty))
        #expect(FormatterGuard.check(input: input, output: "Oczywiście, nie przyjdę.") == .rejected(.answered))
        #expect(FormatterGuard.check(input: input, output: "Tak.") == .rejected(.tooShort))
        #expect(FormatterGuard.check(input: input + " " + input, output: "Tak.") == .rejected(.tooShort))
    }
}
