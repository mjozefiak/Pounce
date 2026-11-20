import Foundation

@testable import DictationPlugin

/// Items, gold decisions and metrics for the span-selection prototype. All texts come from the invented
/// autocorrect corpus and the invented guard probe tables.
enum SpanEval {
    struct Item {
        let id: String
        let lang: String
        /// Corpus category, or `probe` for a guard probe.
        let category: String
        let raw: String
        /// Correct cleanups of `raw` (the corpus' `expected`, or the `ok` outputs of the probes). Empty: unlabeled.
        let refs: [String]
        /// Outputs the reviewers listed as wrong for this input (probes only).
        var bads: [String] = []
        let corpus: AutocorrectCorpus.Case?

        var isNegative: Bool { category == "negative" }
        var isProbe: Bool { category == "probe" }
    }

    static func items() throws -> [Item] {
        var result = try AutocorrectCorpus.load().map {
            Item(id: $0.id, lang: $0.lang, category: $0.category, raw: $0.raw, refs: [$0.expected], corpus: $0)
        }
        var order: [String] = []
        var ids: [String: String] = [:]
        var refs: [String: [String]] = [:]
        var bads: [String: [String]] = [:]
        let corpusRaw = Set(result.map(\.raw))
        for row in GuardProbeTests.table where !corpusRaw.contains(row.input) {
            if refs[row.input] == nil {
                order.append(row.input)
                ids[row.input] = row.id
                refs[row.input] = []
            }
            if row.ok { refs[row.input]?.append(row.output) } else { bads[row.input, default: []].append(row.output) }
        }
        for input in order {
            let polish = Language.dominant(in: input) == .polish
            result.append(
                Item(
                    id: ids[input] ?? "?", lang: polish ? "pl" : "en", category: "probe", raw: input,
                    refs: refs[input] ?? [], bads: bads[input] ?? [], corpus: nil))
        }
        return result
    }

    // MARK: text distance

    static func tokens(_ text: String) -> [String] { AutocorrectCorpus.tokens(text) }

    static func distance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count]
    }

    static func multisetMinus(_ a: [String], _ b: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for word in b { counts[word, default: 0] += 1 }
        var left: [String] = []
        for word in a {
            if let count = counts[word], count > 0 { counts[word] = count - 1 } else { left.append(word) }
        }
        return left
    }

    static func negations(_ tokens: [String], polish: Bool) -> Int {
        tokens.filter { FormatterGuard.negates($0, polish: polish) }.count
    }

    // MARK: gold

    struct Gold {
        let decision: SpanSelect.Decision
        let text: String
        /// The reference the gold result is closest to.
        let ref: String
        /// Whether the gold result is a correct cleanup: for the corpus the `must_keep`/`must_drop` words, for
        /// the probes at most 2 words from a reference.
        let solvable: Bool
    }

    /// The decision, among `none` and every start before the first marker, whose result is closest to a
    /// reference (ties: `none`, then the shorter removal). Only for a chunk with one callable marker.
    static func gold(_ item: Item) -> Gold? {
        guard !item.refs.isEmpty else { return nil }
        let words = SpanSelect.words(item.raw)
        guard let marker = SpanSelect.marker(in: words.map(SpanSelect.key)), marker.start > 0 else { return nil }
        var decisions: [SpanSelect.Decision] = [.none]
        decisions += (0..<marker.start).reversed().map { .start($0) }
        var best: (decision: SpanSelect.Decision, text: String, ref: String, distance: Int)?
        for decision in decisions {
            let text = SpanSelect.apply(words, marker: marker, decision: decision).joined(separator: " ")
            for ref in item.refs {
                let d = distance(tokens(text), tokens(ref))
                if best == nil || d < best!.distance { best = (decision, text, ref, d) }
            }
        }
        guard let best else { return nil }
        let solvable: Bool
        if let corpus = item.corpus {
            // Among the results that satisfy the case, the closest to `expected`.
            let satisfying = decisions.compactMap { decision -> (SpanSelect.Decision, String, Int)? in
                let text = SpanSelect.apply(words, marker: marker, decision: decision).joined(separator: " ")
                guard AutocorrectCorpus.satisfies(text, corpus) else { return nil }
                return (decision, text, distance(tokens(text), tokens(item.refs[0])))
            }
            if let pick = satisfying.min(by: { $0.2 < $1.2 }) {
                return Gold(decision: pick.0, text: pick.1, ref: item.refs[0], solvable: true)
            }
            solvable = false
        } else {
            solvable = best.distance <= 2
        }
        return Gold(decision: best.decision, text: best.text, ref: best.ref, solvable: solvable)
    }

    // MARK: how good is a final text

    struct Quality {
        /// Words the reference has (and the input had) that the result lost.
        let lost: [String]
        /// Words the result keeps that the reference does not have.
        let leftover: [String]
        let negationLost: Bool
        let passes: Bool
    }

    static func quality(_ text: String, of item: Item) -> Quality? {
        guard !item.refs.isEmpty else { return nil }
        let result = tokens(text)
        let input = Set(tokens(item.raw))
        let polish = Language.dominant(in: item.raw) == .polish
        let ref = item.refs.min { distance(result, tokens($0)) < distance(result, tokens($1)) } ?? item.refs[0]
        let refTokens = tokens(ref)
        let lost = multisetMinus(refTokens, result).filter { input.contains($0) }
        let leftover = multisetMinus(result, refTokens)
        let passes: Bool
        if let corpus = item.corpus {
            passes = AutocorrectCorpus.satisfies(text, corpus)
        } else {
            passes = distance(result, refTokens) <= 2
        }
        return Quality(
            lost: lost, leftover: leftover,
            negationLost: negations(result, polish: polish) < negations(refTokens, polish: polish), passes: passes)
    }

    // MARK: decision classes (single callable marker)

    enum Class: String, CaseIterable {
        case exact, offByOneShort, offByOneLong, wrong, missed, correctNone, falseAlarm
    }

    /// `offByOneShort` removes one word too few (starts one word late), `offByOneLong` one word too many.
    static func classify(_ decision: SpanSelect.Decision, against gold: Gold, marker: SpanSelect.Marker) -> Class {
        switch (decision, gold.decision) {
        case (.none, .none): return .correctNone
        case (.start, .none): return .falseAlarm
        case (.none, .start): return .missed
        case (.start(let s), .start(let g)):
            if s == g { return .exact }
            if s == g + 1 { return .offByOneShort }
            if s == g - 1 { return .offByOneLong }
            return .wrong
        }
    }

    // MARK: all decisions (worst case)

    struct Leaf {
        let text: String
        let decisions: [SpanSelect.Decision]
    }

    /// Every result reachable with some choice of decisions, markers resolved left to right like
    /// `SpanSelect.run`; at most `cap` leaves.
    static func leaves(
        _ text: String, limit: Int, rule: Bool, cap: Int = 4000
    ) -> [Leaf] {
        let polish = Language.dominant(in: text) == .polish
        var found: [Leaf] = []
        func walk(_ words: [String], from: Int, decisions: [SpanSelect.Decision]) {
            guard found.count < cap else { return }
            var start = from
            var current: SpanSelect.Marker?
            while let marker = SpanSelect.marker(in: words.map(SpanSelect.key), from: start) {
                if SpanSelect.window(before: marker, limit: limit).isEmpty {
                    start = marker.end
                    continue
                }
                current = marker
                break
            }
            guard let marker = current else {
                found.append(Leaf(text: words.joined(separator: " "), decisions: decisions))
                return
            }
            let window = SpanSelect.window(before: marker, limit: limit)
            let query = SpanSelect.Query(words: words, marker: marker, window: window, polish: polish)
            var options: [SpanSelect.Decision] = [.none] + window.map { .start($0) }
            if rule {
                options = options.map { SpanSelect.negationRule($0, in: query) }
                var seen: [SpanSelect.Decision] = []
                options = options.filter { option in
                    if seen.contains(option) { return false }
                    seen.append(option)
                    return true
                }
            }
            for option in options {
                switch option {
                case .none: walk(words, from: marker.end, decisions: decisions + [option])
                case .start(let s):
                    walk(
                        SpanSelect.apply(words, marker: marker, decision: option), from: s,
                        decisions: decisions + [option])
                }
            }
        }
        walk(SpanSelect.words(text), from: 0, decisions: [])
        return found
    }
}
