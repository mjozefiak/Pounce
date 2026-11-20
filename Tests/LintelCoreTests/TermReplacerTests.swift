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
        "does not replace inside emails, URLs, identifiers, hyphenated words or contractions",
        arguments: [
            "user@lodz.pl", "https://lodz.pl/lodz/x", "my_lodz and lodz_city", "pre-lodz", "lodz-city",
            "C:\\lodz\\x", "don't stop", "don\u{2019}t stop", "a.lodz", "v1.service",
        ])
    func compounds(input: String) {
        let r = TermReplacer(entries: [
            .init(term: "Łódź", aliases: ["lodz"]),
            .init(term: "Done", aliases: ["don"]),
            .init(term: "Svc", aliases: ["service"]),
        ])
        #expect(r.apply(to: input) == input)
    }

    @Test(
        "sentence punctuation does not block a match",
        arguments: [
            ("jadę do lodz.", "jadę do Łódź."), ("(lodz)", "(Łódź)"), ("lodz, ok", "Łódź, ok"),
            ("lodz...", "Łódź..."), ("\"lodz\"", "\"Łódź\""), ("lodz. Potem", "Łódź. Potem"),
            ("lodz-", "Łódź-"), ("lodz!", "Łódź!"),
        ])
    func sentencePunctuation(input: String, expected: String) {
        let r = TermReplacer(entries: [.init(term: "Łódź", aliases: ["lodz"])])
        #expect(r.apply(to: input) == expected)
    }

    @Test("an alias or term with punctuation matches its own text")
    func punctuatedAliases() {
        let r = TermReplacer(entries: [
            .init(term: "GPT-5", aliases: []),
            .init(term: "email", aliases: ["e-mail"]),
        ])
        #expect(r.apply(to: "use gpt-5 and gpt - 5 today") == "use GPT-5 and GPT-5 today")
        #expect(r.apply(to: "send an e-mail, or e - mail") == "send an email, or email")
        #expect(r.apply(to: "e mail and e, mail") == "e mail and e, mail")
        #expect(r.apply(to: "gpt 5") == "gpt 5")
    }

    @Test("a paragraph break never joins an alias")
    func paragraphBreak() {
        let r = replacer()
        #expect(r.apply(to: "auth\nservice") == "AuthService")
        #expect(r.apply(to: "auth\n\nservice") == "auth\n\nservice")
        #expect(r.apply(to: "auth \n \n service") == "auth \n \n service")
    }

    @Test("apply is idempotent")
    func idempotent() {
        let r = TermReplacer(entries: [
            .init(term: "AuthService", aliases: ["auth service"]),
            .init(term: "Seg-One", aliases: []),
            .init(term: "Uno", aliases: ["one"]),
            .init(term: "GPT-5", aliases: ["gpt 5"]),
            .init(term: "email", aliases: ["e-mail"]),
            .init(term: "Łódź", aliases: ["lodz"]),
        ])
        let inputs = [
            "otwórz auth service teraz", "seg-one i one", "gpt 5 oraz gpt-5", "wyślij e-mail do lodz.",
            "user@lodz.pl", "one", "Seg-One, one.",
        ]
        for input in inputs + ["AUTH SERVICE"] {
            let once = r.apply(to: input)
            #expect(r.apply(to: once) == once)
        }
        #expect(r.apply(to: "seg-one i one") == "Seg-One i Uno")
        let table = replacer()
        for input in ["auth service, auth service!", "postgres s q l i postgres sql", "jadę do lodz w piątek"] {
            let once = table.apply(to: input)
            #expect(table.apply(to: once) == once)
        }
    }

    @Test("work does not grow with the number of aliases sharing a first word")
    func manyAliasesSameFirstWord() {
        func run(_ count: Int) -> (result: String, steps: Int, tokens: Int) {
            let entries = (0..<count).map {
                TermReplacer.Entry(term: "Term\($0)", aliases: ["the word\($0) here", "the thing\($0)"])
            }
            let r = TermReplacer(entries: entries)
            // The text only uses the first 20 terms, so it is the same for every count.
            let text = (0..<20).map { $0 % 2 == 0 ? "the thing\($0)" : "the other\($0)" }.joined(separator: " ")
            var steps = 0
            let result = r.apply(to: text, steps: &steps)
            return (result, steps, text.split(separator: " ").count)
        }
        let small = run(1_000)
        let large = run(10_000)
        #expect(small.result.hasPrefix("Term0 the other1 Term2"))
        #expect(large.result == small.result)
        // At most `maximumAliasWords` trie steps per token, and ten times the aliases cost nothing extra.
        #expect(large.steps <= large.tokens * TermReplacer.maximumAliasWords)
        #expect(large.steps == small.steps)
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
