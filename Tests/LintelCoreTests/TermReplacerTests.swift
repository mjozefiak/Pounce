import Foundation
import Testing

@testable import LintelCore

@Suite("TermReplacer")
struct TermReplacerTests {
    private func replacer() -> TermReplacer {
        TermReplacer(entries: [
            .init(term: "AuthService", aliases: ["auth service", "ałt serwis"]),
            .init(term: "Kubernetes", aliases: ["kubernetis", "kubernetes"]),
            .init(term: "Łódź", aliases: ["lodz"]),
            .init(term: "PostgreSQL", aliases: ["postgres", "postgres sql", "postgres s q l"]),
        ])
    }

    @Test(
        "replaces aliases in Polish and English text",
        arguments: [
            ("otwórz auth service teraz", "otwórz AuthService teraz"),
            ("open the Auth Service now", "open the AuthService now"),
            ("uruchom ałt serwis jutro", "uruchom AuthService jutro"),
            ("wdrożenie na kubernetis działa", "wdrożenie na Kubernetes działa"),
            ("jadę do lodz w piątek", "jadę do Łódź w piątek"),
            ("auth service, auth service!", "AuthService, AuthService!"),
            ("AUTH SERVICE", "AuthService"),
        ])
    func replaces(input: String, expected: String) {
        #expect(replacer().apply(to: input) == expected)
    }

    @Test("the term itself fixes capitalisation")
    func termIsAlias() {
        #expect(replacer().apply(to: "the authservice is up") == "the AuthService is up")
    }

    @Test(
        "does not touch the middle of a word",
        arguments: ["planowanie", "preauth service", "auth services", "postgresql2", "kubernetesy"])
    func wordBoundaries(input: String) {
        let plan = TermReplacer(entries: [.init(term: "Plan", aliases: ["plan"])])
        #expect(plan.apply(to: "planowanie") == "planowanie")
        #expect(replacer().apply(to: input) == input)
    }

    @Test("diacritics and case do not matter")
    func diacritics() {
        let r = TermReplacer(entries: [.init(term: "Źródło", aliases: ["zrodlo"])])
        #expect(r.apply(to: "to jest ŹRÓDŁO danych") == "to jest Źródło danych")
        #expect(r.apply(to: "to jest zrodlo") == "to jest Źródło")
    }

    @Test("punctuation breaks a multi-word alias, any white space joins it")
    func gaps() {
        #expect(replacer().apply(to: "auth, service") == "auth, service")
        #expect(replacer().apply(to: "auth.\nservice") == "auth.\nservice")
        #expect(replacer().apply(to: "auth  \n service") == "AuthService")
    }

    @Test("the longest alias wins")
    func longestWins() {
        #expect(
            replacer().apply(to: "postgres s q l i postgres sql i postgres") == "PostgreSQL i PostgreSQL i PostgreSQL")
        let r = TermReplacer(entries: [
            .init(term: "A", aliases: ["new york"]),
            .init(term: "B", aliases: ["new york city"]),
        ])
        #expect(r.apply(to: "new york city") == "B")
        #expect(r.apply(to: "new york times") == "A times")
    }

    @Test("an alias claimed twice belongs to the first entry")
    func collision() {
        let r = TermReplacer(entries: [
            .init(term: "First", aliases: ["dup"]),
            .init(term: "Second", aliases: ["dup"]),
        ])
        #expect(r.apply(to: "a dup b") == "a First b")
    }

    @Test("a replacement is never scanned again")
    func noChaining() {
        let r = TermReplacer(entries: [
            .init(term: "Beta", aliases: ["alpha"]),
            .init(term: "Gamma", aliases: ["beta"]),
        ])
        // "beta" is already the first entry's own spelling; "alpha" is not rewritten twice.
        #expect(r.apply(to: "alpha beta") == "Beta Beta")
        let selfMapping = TermReplacer(entries: [.init(term: "go go", aliases: ["go"])])
        #expect(selfMapping.apply(to: "go") == "go go")
    }

    @Test("empty vocabulary and blank entries leave the text unchanged")
    func empty() {
        let text = "  Zażółć  gęślą, jaźń!  "
        #expect(TermReplacer(entries: []).isEmpty)
        #expect(TermReplacer(entries: []).apply(to: text) == text)
        let blank = TermReplacer(entries: [.init(term: "  ", aliases: ["x"]), .init(term: "T", aliases: ["", "..."])])
        #expect(blank.apply(to: text) == text)
        #expect(blank.apply(to: "t") == "T")
    }

    @Test("text around matches is kept exactly")
    func preserves() {
        #expect(replacer().apply(to: "  (auth service)\t— ok…") == "  (AuthService)\t— ok…")
        #expect(replacer().apply(to: "") == "")
    }

    @Test("digits are part of tokens")
    func digits() {
        let r = TermReplacer(entries: [.init(term: "GPT-5", aliases: ["gpt 5", "g p t 5"])])
        #expect(r.apply(to: "use gpt 5 today, not gpt 50") == "use GPT-5 today, not gpt 50")
    }

    @Test("overlong aliases are ignored")
    func overlong() {
        let alias = Array(repeating: "w", count: TermReplacer.maximumAliasWords + 1).joined(separator: " ")
        #expect(TermReplacer(entries: [.init(term: "X", aliases: [alias])]).apply(to: alias) == alias)
    }

    @Test(
        "performance: 500 words and 200 terms (off by default, set LINTEL_PERF=1)",
        .enabled(if: ProcessInfo.processInfo.environment["LINTEL_PERF"] == "1"))
    func performance() {
        let entries = (0..<200).map {
            TermReplacer.Entry(term: "Term\($0)", aliases: ["alias \($0) one", "zed\($0)"])
        }
        let words = (0..<500).map { $0 % 7 == 0 ? "alias \($0 % 200) one" : "slowo\($0)" }
        let text = words.joined(separator: " ")
        let replacer = TermReplacer(entries: entries)
        let elapsed = ContinuousClock().measure { _ = replacer.apply(to: text) }
        print("TermReplacer 500 words / 200 terms: \(elapsed)")
        #expect(elapsed < .milliseconds(20))
    }
}
