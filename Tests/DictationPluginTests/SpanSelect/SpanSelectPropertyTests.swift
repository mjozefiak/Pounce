import Foundation
import Testing

@testable import DictationPlugin

/// Model-free tests of the span-selection prototype: what the code guarantees for EVERY decision a model
/// could return, and the worst case over the whole decision space. Texts are the invented corpus and probes.
@Suite struct SpanSelectPropertyTests {
    static let limits = [4, 6, 8, 12]

    private func isSubsequence(_ small: [String], of big: [String]) -> Bool {
        var index = 0
        for word in big where index < small.count && small[index] == word { index += 1 }
        return index == small.count
    }

    // MARK: guarantees

    @Test func everyDecisionKeepsTheInputWordsInOrderAndEverythingAfterTheMarker() throws {
        var checked = 0
        for item in try SpanEval.items() {
            let words = SpanSelect.words(item.raw)
            guard let marker = SpanSelect.marker(in: words.map(SpanSelect.key)) else { continue }
            var decisions: [SpanSelect.Decision] = [.none]
            decisions += (0..<marker.start).map { .start($0) }
            for decision in decisions {
                let result = SpanSelect.apply(words, marker: marker, decision: decision)
                #expect(isSubsequence(result, of: words), "\(item.id)")
                #expect(Set(result).isSubset(of: Set(words)), "\(item.id)")
                #expect(Array(result.suffix(words.count - marker.end)) == Array(words[marker.end...]), "\(item.id)")
                if case .start(let start) = decision {
                    // One contiguous span that ends exactly at the marker's last word.
                    #expect(result == Array(words[..<start]) + Array(words[marker.end...]), "\(item.id)")
                    #expect(words.count - result.count == marker.end - start, "\(item.id)")
                } else {
                    #expect(result == words, "\(item.id)")
                }
                checked += 1
            }
        }
        #expect(checked > 500)
    }

    @Test func chainsOfSeveralMarkersStayASubsequenceWithoutForeignWords() throws {
        var chains = 0
        for item in try SpanEval.items() {
            let words = SpanSelect.words(item.raw)
            for rule in [false, true] {
                for leaf in SpanEval.leaves(item.raw, limit: 12, rule: rule) {
                    let result = SpanSelect.words(leaf.text)
                    #expect(isSubsequence(result, of: words), "\(item.id)")
                    #expect(leaf.decisions.count >= 0)
                    if leaf.decisions.count > 1 { chains += 1 }
                }
            }
        }
        #expect(chains > 0)
    }

    /// A start at or before the first withdrawn word never leaves a withdrawn word that is not repeated after
    /// the marker, and never touches a word after the marker: the retracted and the final version cannot both
    /// remain.
    @Test func aCoveringStartNeverKeepsTheWithdrawnVersion() throws {
        var covered = 0
        for item in try SpanEval.items() {
            guard let corpus = item.corpus, AutocorrectCorpus.withdrawing.contains(item.category) else { continue }
            let words = SpanSelect.words(item.raw)
            let keys = words.map(SpanSelect.key)
            guard let marker = SpanSelect.marker(in: keys), marker.start > 0 else { continue }
            let withdrawn = AutocorrectCorpus.withdrawnWords(corpus)
            let after = Set(keys[marker.end...])
            let positions = (0..<marker.start).filter { index in
                withdrawn.contains { AutocorrectCorpus.forms($0).contains(keys[index]) }
            }
            guard let first = positions.min() else { continue }
            for start in 0...first {
                let result = SpanSelect.apply(words, marker: marker, decision: .start(start)).map(SpanSelect.key)
                for entry in withdrawn {
                    let forms = AutocorrectCorpus.forms(entry)
                    if forms.contains(where: after.contains) { continue }
                    #expect(!result.contains { forms.contains($0) }, "\(item.id) start \(start)")
                }
                #expect(Array(result.suffix(keys.count - marker.end)) == Array(keys[marker.end...]))
                covered += 1
            }
        }
        #expect(covered > 100)
    }

    @Test func theNegationRuleNeverLetsACutDropANegationWithoutLeavingOne() throws {
        for item in try SpanEval.items() {
            let words = SpanSelect.words(item.raw)
            let keys = words.map(SpanSelect.key)
            guard let marker = SpanSelect.marker(in: keys), marker.start > 0 else { continue }
            let polish = Language.dominant(in: item.raw) == .polish
            let query = SpanSelect.Query(
                words: words, marker: marker, window: SpanSelect.window(before: marker, limit: 12), polish: polish)
            let left = keys[marker.end...].contains { FormatterGuard.negates($0, polish: polish) }
            for start in query.window {
                let decision = SpanSelect.negationRule(.start(start), in: query)
                let removed = keys[start..<marker.start].contains { FormatterGuard.negates($0, polish: polish) }
                if case .start = decision { #expect(!removed || left, "\(item.id) \(start)") }
                if removed && !left { #expect(decision == .none, "\(item.id) \(start)") }
            }
        }
    }

    // MARK: parsing and grammar

    @Test func anInvalidOrOutOfWindowAnswerMeansNone() {
        let window = 3..<8
        #expect(SpanSelect.parse("none", window: window) == (.none, true))
        #expect(SpanSelect.parse(" NONE\n", window: window) == (.none, true))
        #expect(SpanSelect.parse("4", window: window) == (.start(3), true))
        #expect(SpanSelect.parse("8", window: window) == (.start(7), true))
        for bad in ["2", "9", "0", "-1", "3 4", "start 4", "", "I think 5", "4."] {
            let parsed = SpanSelect.parse(bad, window: window)
            #expect(parsed.decision == .none && !parsed.valid, "\(bad)")
        }
    }

    @Test func theGrammarAllowsOnlyNoneAndTheWindowNumbers() {
        #expect(SpanSelect.grammar(for: 2..<5) == "root ::= \"none\" | \"3\" | \"4\" | \"5\"")
        #expect(SpanSelect.window(before: .init(start: 3, end: 5), limit: 8) == 0..<3)
        #expect(SpanSelect.window(before: .init(start: 20, end: 22), limit: 8) == 12..<20)
    }

    @Test func markersAreFoundLeftToRightLongestFirst() {
        let keys = ["a", "b", "nie", "czekaj", "c", "to", "znaczy", "d"].map { $0 }
        #expect(SpanSelect.marker(in: keys) == .init(start: 2, end: 4))
        #expect(SpanSelect.marker(in: keys, from: 4) == .init(start: 5, end: 7))
        #expect(SpanSelect.marker(in: ["a", "nie", "to", "znaczy"]) == .init(start: 1, end: 4))
        #expect(SpanSelect.marker(in: ["bez", "markera"]) == nil)
    }

    @Test func runResolvesSeveralMarkersAndTreatsNoneAsContent() {
        let text = "we meet on monday sorry on tuesday and ship it actually on friday"
        var queries: [SpanSelect.Query] = []
        let outcome = SpanSelect.run(text, limit: 8, negationRule: true) { query in
            queries.append(query)
            // First marker: remove "on monday"; second: leave it as content.
            return queries.count == 1 ? .start(2) : .none
        }
        #expect(outcome.text == "we meet on tuesday and ship it actually on friday")
        #expect(outcome.calls == 2)
        let marked = SpanSelect.run("sorry for the delay", limit: 8, negationRule: true) { _ in .start(0) }
        #expect(marked.calls == 0 && marked.text == "sorry for the delay")
    }

    @Test func promptExamplesAreNotCorpusCases() throws {
        let corpus = try AutocorrectCorpus.load()
        for example in SpanSelect.examples {
            let plain = example.text.replacingOccurrences(
                of: "\\[\\d+\\]", with: "", options: .regularExpression
            ).replacingOccurrences(of: "<<", with: "").replacingOccurrences(of: ">>", with: "")
            #expect(CleanupPromptCorpusSeparationTests.overlaps(plain, corpus: corpus).isEmpty, "\(plain)")
        }
        #expect(
            SpanSelect.messages(for: .init(words: ["a"], marker: .init(start: 0, end: 1), window: 0..<0, polish: false))
                .count == 2 + SpanSelect.examples.count * 2)
    }

    // MARK: the worst case (no model)

    struct Tally {
        var items = 0
        var decisions = 0
        var overRemoval = 0
        var negationLost = 0
        var itemsOverRemovable = 0
        var itemsNegationLostPossible = 0
    }

    /// The worst case over every decision of every labeled item with a callable marker.
    static func tally(_ items: [SpanEval.Item], limit: Int, rule: Bool) -> Tally {
        var tally = Tally()
        for item in items {
            guard SpanSelect.marker(in: SpanSelect.words(item.raw).map(SpanSelect.key)).map({ $0.start > 0 }) == true
            else { continue }
            tally.items += 1
            var over = false
            var lostNegation = false
            for leaf in SpanEval.leaves(item.raw, limit: limit, rule: rule) {
                guard let quality = SpanEval.quality(leaf.text, of: item) else { continue }
                tally.decisions += 1
                if !quality.lost.isEmpty {
                    tally.overRemoval += 1
                    over = true
                }
                if quality.negationLost {
                    tally.negationLost += 1
                    lostNegation = true
                }
            }
            if over { tally.itemsOverRemovable += 1 }
            if lostNegation { tally.itemsNegationLostPossible += 1 }
        }
        return tally
    }

    @Test func printsTheModelFreeUpperBoundOfHarm() throws {
        let all = try SpanEval.items()
        let labeled = all.filter { !$0.refs.isEmpty }
        let groups: [(String, [SpanEval.Item])] = [
            ("corpus withdrawals", labeled.filter { AutocorrectCorpus.withdrawing.contains($0.category) }),
            ("corpus negatives", labeled.filter(\.isNegative)),
            ("corpus falsestart+filler", labeled.filter { ["falsestart", "filler"].contains($0.category) }),
            ("probes with a correct cleanup", labeled.filter(\.isProbe)),
        ]
        print(
            "[span-items] corpus \(all.filter { !$0.isProbe }.count) probes \(all.filter(\.isProbe).count)"
                + " (labeled \(all.filter { $0.isProbe && !$0.refs.isEmpty }.count), unlabeled"
                + " \(all.filter { $0.isProbe && $0.refs.isEmpty }.count));"
                + " with a callable marker: "
                + groups.map { "\($0.0) \(Self.tally($0.1, limit: 100, rule: false).items)" }.joined(separator: ", "))
        for (name, items) in groups {
            for limit in Self.limits + [100] {
                let plain = Self.tally(items, limit: limit, rule: false)
                let ruled = Self.tally(items, limit: limit, rule: true)
                print(
                    "[span-worstcase] \(name) N=\(limit == 100 ? "all" : String(limit)) items \(plain.items)"
                        + " | no rule: decisions \(plain.decisions) overRemoval \(plain.overRemoval)"
                        + " negationLost \(plain.negationLost) itemsHarmable \(plain.itemsOverRemovable)"
                        + " itemsNegationLostPossible \(plain.itemsNegationLostPossible)"
                        + " | rule: decisions \(ruled.decisions) overRemoval \(ruled.overRemoval)"
                        + " negationLost \(ruled.negationLost) itemsHarmable \(ruled.itemsOverRemovable)"
                        + " itemsNegationLostPossible \(ruled.itemsNegationLostPossible)")
            }
        }
        let chained = all.filter { item in
            SpanEval.leaves(item.raw, limit: 8, rule: false).contains { $0.decisions.count >= 2 }
        }
        print(
            "[span-items] chunks with two or more callable markers: \(chained.count)"
                + " (corpus \(chained.filter { !$0.isProbe }.count), probes \(chained.filter(\.isProbe).count))")
        // Unlabeled probes: how many have a negation before the marker that some start could drop.
        let unlabeled = all.filter { $0.isProbe && $0.refs.isEmpty }
        for limit in Self.limits + [100] {
            var callable = 0
            var droppable = 0
            var droppableWithRule = 0
            for item in unlabeled {
                let words = SpanSelect.words(item.raw)
                let keys = words.map(SpanSelect.key)
                guard let marker = SpanSelect.marker(in: keys), marker.start > 0 else { continue }
                callable += 1
                let polish = Language.dominant(in: item.raw) == .polish
                let window = SpanSelect.window(before: marker, limit: limit)
                let query = SpanSelect.Query(words: words, marker: marker, window: window, polish: polish)
                let drops = window.contains { start in
                    keys[start..<marker.start].contains { FormatterGuard.negates($0, polish: polish) }
                }
                let survives = window.contains { start in
                    SpanSelect.negationRule(.start(start), in: query) == .start(start)
                        && keys[start..<marker.start].contains { FormatterGuard.negates($0, polish: polish) }
                }
                if drops { droppable += 1 }
                if survives { droppableWithRule += 1 }
            }
            print(
                "[span-worstcase] unlabeled probes N=\(limit == 100 ? "all" : String(limit)) callable \(callable)"
                    + " negationDroppable(no rule) \(droppable)"
                    + " negationDroppableWhileAnotherRemains(rule) \(droppableWithRule)")
        }
        // Ceiling: how many withdrawals have a correct cleanup that one span of at most N words produces.
        let withdrawals = groups[0].1.filter { SpanEval.gold($0)?.solvable == true }
        for limit in Self.limits + [100] {
            var reachable = 0
            var single = 0
            for item in withdrawals {
                guard let gold = SpanEval.gold(item) else { continue }
                single += 1
                let words = SpanSelect.words(item.raw)
                guard let marker = SpanSelect.marker(in: words.map(SpanSelect.key)),
                    case .start(let start) = gold.decision
                else { continue }
                if SpanSelect.window(before: marker, limit: limit).contains(start) { reachable += 1 }
            }
            print(
                "[span-ceiling] withdrawals with a gold span N=\(limit == 100 ? "all" : String(limit))"
                    + " reachable \(reachable)/\(single)")
        }
        let unsolvable = groups[0].1.filter { SpanEval.gold($0)?.solvable != true }.map(\.id).sorted()
        print("[span-ceiling] withdrawals no span cut can solve (\(unsolvable.count)): \(unsolvable)")
        #expect(!withdrawals.isEmpty)
    }
}
