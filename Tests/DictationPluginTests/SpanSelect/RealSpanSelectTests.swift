import Foundation
import Testing

@testable import DictationPlugin

/// Real-model measurement of span selection (off by default, like the other real-model harnesses; never run
/// in CI). Run it alone, once per model:
/// `LINTEL_SPAN_MODEL=<gguf> LINTEL_SPAN_LABEL=<name> LINTEL_SPAN_NS=4,8,12 swift test --filter RealSpanSelectTests`.
/// Prints counts and invented ids only; `LINTEL_SPAN_OUT=<dir>` also writes the decisions and the final texts
/// as JSON there (to compare runs). `LINTEL_SPAN_NOCACHE=1` decodes every prompt from scratch, as
/// `LlamaRuntime` does today. `LINTEL_SPAN_E2E=1` adds the cleanup step for every `N` and every rule set.
@Suite struct RealSpanSelectTests {
    struct Call {
        let decision: SpanSelect.Decision
        let valid: Bool
        let answer: String
        let seconds: Double
        let promptTokens: Int
        let decodedTokens: Int
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The counts of the real-model corpus test of PR 134, for texts that came out of some pipeline, plus the
    /// strict score (`SpanEval.strictPasses`) on the same texts.
    static func printEndToEnd(_ tag: String, _ texts: [(SpanEval.Item, String)]) {
        var passed = 0
        var strict = 0
        var withdrawalPassed = 0
        var withdrawalStrict = 0
        var withdrawals = 0
        var negativePassed = 0
        var negatives = 0
        var lostFinal: [String] = []
        var keptWithdrawn: [String] = []
        var both: [String] = []
        var changedNegation: [String] = []
        var overRemoved: [String] = []
        var maxLost = 0
        for (item, text) in texts {
            guard let corpus = item.corpus else { continue }
            let ok = AutocorrectCorpus.satisfies(text, corpus)
            let isStrict = SpanEval.strictPasses(text, of: item)
            if ok { passed += 1 }
            if isStrict { strict += 1 }
            maxLost = max(maxLost, SpanEval.quality(text, of: item)?.lost.count ?? 0)
            let words = Set(AutocorrectCorpus.tokens(text))
            let polish = Language.dominant(in: item.raw) == .polish
            if AutocorrectCorpus.withdrawing.contains(item.category) {
                withdrawals += 1
                if ok { withdrawalPassed += 1 }
                if isStrict { withdrawalStrict += 1 }
                let finalKept = corpus.mustKeep.allSatisfy { AutocorrectCorpus.holds(words, $0) }
                if !finalKept { lostFinal.append(item.id) }
                if AutocorrectCorpus.keepsWithdrawn(text, corpus) {
                    keptWithdrawn.append(item.id)
                    if finalKept { both.append(item.id) }
                }
            }
            if item.isNegative {
                negatives += 1
                if ok { negativePassed += 1 } else { overRemoved.append(item.id) }
            }
            if AutocorrectCorpusTests.negations(in: text, polish: polish)
                != AutocorrectCorpusTests.negations(in: corpus.expected, polish: polish)
            {
                changedNegation.append(item.id)
            }
        }
        print(
            "\(tag): passed \(passed)/\(texts.count) withdrawals \(withdrawalPassed)/\(withdrawals)"
                + " negatives \(negativePassed)/\(negatives) | strict \(strict) (withdrawals \(withdrawalStrict))"
                + " maxLostWords \(maxLost) | lostFinal \(lostFinal.count) \(lostFinal.sorted())"
                + " keptWithdrawn \(keptWithdrawn.count) bothVersions \(both.count) \(both.sorted())"
                + " changedNegation \(changedNegation.count) \(changedNegation.sorted())"
                + " overRemovedNegatives \(overRemoved.count) \(overRemoved.sorted())")
    }

    static func peakResidentMegabytes() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    /// The rule sets measured after the model's answer, left to right unless `fromEnd`.
    struct Variant {
        let name: String
        let rules: SpanSelect.Rules
        var fromEnd = false
    }

    static let variants: [Variant] = [
        Variant(name: "none", rules: []),
        Variant(name: "neg", rules: [.negation]),
        Variant(name: "neg+align", rules: [.negation, .align]),
        Variant(name: "neg+align+tail", rules: [.negation, .align, .requireRepair]),
        Variant(name: "neg+align+tail+anchorNeg", rules: [.negation, .align, .requireRepair, .anchorNegatingMarkers]),
        Variant(name: "neg+align+anchorAll", rules: [.negation, .align, .anchorAll]),
        Variant(name: "fromEnd neg", rules: [.negation], fromEnd: true),
        Variant(name: "fromEnd neg+align+tail", rules: [.negation, .align, .requireRepair], fromEnd: true),
        Variant(
            name: "fromEnd neg+align+tail+anchorNeg",
            rules: [.negation, .align, .requireRepair, .anchorNegatingMarkers],
            fromEnd: true),
    ]

    /// The cut-only metrics of one rule set (also used by the replay test).
    static func printCutMetrics(
        _ printTag: String, items: [SpanEval.Item], outcomes: [SpanSelect.Outcome], limit: Int
    ) {
        func outcome(_ i: Int) -> SpanSelect.Outcome { outcomes[i] }
        let corpusIndices = items.indices.filter { !items[$0].isProbe }
        func passes(_ i: Int) -> Bool { SpanEval.quality(outcome(i).text, of: items[i])?.passes ?? false }
        func strict(_ i: Int) -> Bool { SpanEval.strictPasses(outcome(i).text, of: items[i]) }
        let withdrawals = corpusIndices.filter { AutocorrectCorpus.withdrawing.contains(items[$0].category) }
        let negatives = corpusIndices.filter { items[$0].isNegative }
        let others = corpusIndices.filter {
            !AutocorrectCorpus.withdrawing.contains(items[$0].category) && !items[$0].isNegative
        }
        print(
            "\(printTag) corpus pass \(corpusIndices.filter(passes).count)/\(corpusIndices.count)"
                + " withdrawals \(withdrawals.filter(passes).count)/\(withdrawals.count)"
                + " negatives \(negatives.filter(passes).count)/\(negatives.count)"
                + " falsestart+filler \(others.filter(passes).count)/\(others.count)"
                + " | strict \(corpusIndices.filter(strict).count)"
                + " (withdrawals \(withdrawals.filter(strict).count))"
                + " (the cleanup step after the cut is not applied here)")
        print("\(printTag) withdrawals failing: \(withdrawals.filter { !passes($0) }.map { items[$0].id }.sorted())")
        print(
            "\(printTag) negatives changed (false alarms): "
                + "\(negatives.filter { outcome($0).text != items[$0].raw }.map { items[$0].id }.sorted())"
                + " called \(negatives.filter { outcome($0).calls > 0 }.count)/\(negatives.count)")

        // Start accuracy on the single-marker items with a gold decision (decision after the rules).
        var classes: [String: [SpanEval.Class: [String]]] = [:]
        for i in items.indices {
            let o = outcome(i)
            let item = items[i]
            guard o.steps.count == 1, let gold = SpanEval.gold(item), gold.solvable else { continue }
            let kind = item.isProbe ? "probes" : (item.isNegative ? "negatives" : "corpus withdrawals")
            guard !(kind == "corpus withdrawals" && !AutocorrectCorpus.withdrawing.contains(item.category))
            else { continue }
            let step = o.steps[0]
            let cls = SpanEval.classify(step.decision, against: gold, marker: step.marker)
            classes[kind, default: [:]][cls, default: []].append(item.id)
        }
        for kind in classes.keys.sorted() {
            let counts = SpanEval.Class.allCases.compactMap { cls -> String? in
                guard let ids = classes[kind]?[cls] else { return nil }
                return "\(cls.rawValue) \(ids.count)"
            }
            let total = classes[kind]?.values.map(\.count).reduce(0, +) ?? 0
            print("\(printTag) start accuracy \(kind) (n=\(total)): " + counts.joined(separator: ", "))
            if kind == "corpus withdrawals" {
                for cls in [SpanEval.Class.wrong, .offByOneLong, .offByOneShort, .missed] {
                    if let ids = classes[kind]?[cls] { print("\(printTag)   \(cls.rawValue): \(ids.sorted())") }
                }
            }
        }

        // Harm in the final texts of labeled items.
        var overRemoved: [String] = []
        var negationLost: [String] = []
        var probeFalseAlarms: [String] = []
        var maxLost = 0
        var maxSpan = 0
        for i in items.indices {
            let o = outcome(i)
            for step in o.steps {
                if case .start(let s) = step.decision { maxSpan = max(maxSpan, step.marker.end - s) }
            }
            guard !items[i].refs.isEmpty, let quality = SpanEval.quality(o.text, of: items[i]) else { continue }
            maxLost = max(maxLost, quality.lost.count)
            if !quality.lost.isEmpty { overRemoved.append(items[i].id) }
            if quality.negationLost { negationLost.append(items[i].id) }
            if items[i].isProbe, let gold = SpanEval.gold(items[i]), gold.decision == .none,
                o.text != items[i].raw
            {
                probeFalseAlarms.append(items[i].id)
            }
        }
        print(
            "\(printTag) final texts over-removed (lost a reference word) \(overRemoved.count) \(overRemoved.sorted())"
                + " | negation lost \(negationLost.count) \(negationLost.sorted())"
                + " | probe false alarms \(probeFalseAlarms.count) \(probeFalseAlarms.sorted())"
                + " | max reference words lost in one text \(maxLost), longest removed span \(maxSpan) words")

        let badHits = items.indices.filter { i in
            items[i].bads.contains { SpanEval.tokens($0) == SpanEval.tokens(outcome(i).text) }
        }.map { items[$0].id }
        var negationDropped: [String] = []
        for i in items.indices where items[i].refs.isEmpty && items[i].isProbe {
            let o = outcome(i)
            let polish = Language.dominant(in: items[i].raw) == .polish
            let markerNegations = o.steps.filter { $0.decision != .none }
                .map { SpanEval.negations($0.markerKeys, polish: polish) }.reduce(0, +)
            let dropped =
                SpanEval.negations(SpanEval.tokens(items[i].raw), polish: polish)
                - SpanEval.negations(SpanEval.tokens(o.text), polish: polish) - markerNegations
            if dropped > 0 { negationDropped.append(items[i].id) }
        }
        print(
            "\(printTag) result equals a reviewer's known-bad output: \(badHits.count) \(badHits.sorted())"
                + " | unlabeled probes that lose a negation outside the marker: "
                + "\(negationDropped.count) \(negationDropped.sorted())")

        let labeledProbes = items.indices.filter { items[$0].isProbe && !items[$0].refs.isEmpty }
        let unlabeled = items.indices.filter { items[$0].isProbe && items[$0].refs.isEmpty }
        let changed = unlabeled.filter { outcome($0).text != items[$0].raw }
        print(
            "\(printTag) probes labeled pass \(labeledProbes.filter(passes).count)/\(labeledProbes.count)"
                + " strict \(labeledProbes.filter(strict).count)"
                + " | unlabeled probes: called \(unlabeled.filter { outcome($0).calls > 0 }.count)/\(unlabeled.count),"
                + " cut \(changed.count) \(changed.map { items[$0].id }.sorted())")

        // Chains: labeled chunks with two or more callable markers in the raw text (the same set for
        // every variant).
        let chains = items.indices.filter { !items[$0].refs.isEmpty && SpanEval.isChain(items[$0].raw, limit: limit) }
        print(
            "\(printTag) chains (labeled, two or more callable markers): \(chains.count),"
                + " pass \(chains.filter(passes).count), strict \(chains.filter(strict).count)"
                + " failing \(chains.filter { !passes($0) }.map { items[$0].id }.sorted())")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINTEL_SPAN_MODEL"] != nil))
    func measure() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["LINTEL_SPAN_MODEL"])
        let label = environment["LINTEL_SPAN_LABEL"] ?? "model"
        let limits = (environment["LINTEL_SPAN_NS"] ?? "8").split(separator: ",").compactMap { Int($0) }
        let reuse = environment["LINTEL_SPAN_NOCACHE"] == nil
        let loadStart = ContinuousClock.now
        let runtime = try SpanLlama(path: path)
        let load = ContinuousClock.now - loadStart
        print("[span-\(label)] load \(load) prefix cache \(reuse ? "on" : "off")")
        let items = try SpanEval.items()
        var json: [String: Any] = ["label": label, "cache": reuse]

        // First call after the load: nothing is cached yet (the cold start of a first dictation).
        if let first = items.first(where: { SpanSelect.marker(in: SpanSelect.words($0.raw).map(SpanSelect.key)) != nil }
        ) {
            _ = try SpanSelect.run(first.raw, limit: limits[0], rules: []) { query in
                let answer = try runtime.answer(
                    messages: SpanSelect.messages(for: query).map { ($0.role, $0.content) },
                    grammar: SpanSelect.grammar(for: query.window), reuseCache: false)
                print(String(format: "[span-\(label)] first call after load %.3fs", answer.seconds))
                return .none
            }
        }

        var cleanMemo: [String: (text: String, verdict: String, model: String)] = [:]
        var cleanSeconds: [Double] = []
        func clean(_ text: String) throws -> (text: String, verdict: String, model: String) {
            if let known = cleanMemo[text] { return known }
            let words = FormatterGuard.words(in: text)
            let answer = try runtime.answer(
                messages: MainPromptV1.messages(transcript: text), grammar: nil, reuseCache: reuse,
                maxTokens: words * 4 + 64)
            cleanSeconds.append(answer.seconds)
            let result: (text: String, verdict: String, model: String)
            switch MainGuardReference.check(input: text, output: answer.text) {
            case .accepted(let cleaned): result = (cleaned, "accepted", FormatterGuard.clean(answer.text))
            case .rejected(let reason): result = (text, "\(reason)", FormatterGuard.clean(answer.text))
            }
            cleanMemo[text] = result
            return result
        }

        for limit in limits {
            var memo: [String: Call] = [:]
            var fresh: [Call] = []
            var invalid = 0
            func decide(_ query: SpanSelect.Query) throws -> SpanSelect.Decision {
                let messages = SpanSelect.messages(for: query)
                let key = "\(query.window)|" + SpanSelect.userMessage(query)
                if let known = memo[key] { return known.decision }
                let answer = try runtime.answer(
                    messages: messages.map { ($0.role, $0.content) }, grammar: SpanSelect.grammar(for: query.window),
                    reuseCache: reuse)
                let parsed = SpanSelect.parse(answer.text, window: query.window)
                if !parsed.valid { invalid += 1 }
                let call = Call(
                    decision: parsed.decision, valid: parsed.valid, answer: answer.text, seconds: answer.seconds,
                    promptTokens: answer.promptTokens, decodedTokens: answer.decodedTokens)
                memo[key] = call
                fresh.append(call)
                return call.decision
            }

            // outcomes[variant][item index]
            var outcomes: [[SpanSelect.Outcome]] = []
            for variant in Self.variants {
                var row: [SpanSelect.Outcome] = []
                for item in items {
                    row.append(
                        variant.fromEnd
                            ? try SpanSelect.runFromEnd(item.raw, limit: limit, rules: variant.rules, decide: decide)
                            : try SpanSelect.run(item.raw, limit: limit, rules: variant.rules, decide: decide))
                }
                outcomes.append(row)
            }
            let corpusIndices = items.indices.filter { !items[$0].isProbe }

            for (v, variant) in Self.variants.enumerated() {
                let tag = "[span-\(label) N=\(limit) \(variant.name)]"
                // The PR's own tags for the two original rule sets, so the old lines can be compared.
                let legacy = variant.name == "none" ? "rule=off" : (variant.name == "neg" ? "rule=on" : nil)
                let printTag = legacy.map { "[span-\(label) N=\(limit) \($0)]" } ?? tag
                Self.printCutMetrics(printTag, items: items, outcomes: outcomes[v], limit: limit)
            }

            // The off-by-one starts of the model (no rules): direction and the class of the boundary word.
            var boundary: [String: Int] = [:]
            for i in items.indices {
                let o = outcomes[0][i]
                guard o.steps.count == 1, let gold = SpanEval.gold(items[i]), gold.solvable,
                    case .start(let s) = o.steps[0].decision, case .start(let g) = gold.decision, abs(s - g) == 1
                else { continue }
                let words = SpanSelect.words(items[i].raw)
                let polish = Language.dominant(in: items[i].raw) == .polish
                // Short: the gold start word stays. Long: the model's start word is removed although it is kept.
                let word = s > g ? words[g] : words[s]
                let set = items[i].isProbe ? "probes" : "corpus"
                let direction = s > g ? "short" : "long"
                let onset = o.steps[0].marker.end < words.count ? words[o.steps[0].marker.end] : ""
                let repeated = SpanSelect.folded(SpanSelect.key(word)) == SpanSelect.folded(SpanSelect.key(onset))
                boundary[
                    "\(set) \(direction) \(SpanEval.wordClass(SpanSelect.key(word), polish: polish))"
                        + " \(repeated ? "repeated-after-marker" : "not-repeated")", default: 0] += 1
            }
            print(
                "[span-\(label) N=\(limit)] off-by-one boundary words: "
                    + boundary.keys.sorted().map { "\($0): \(boundary[$0] ?? 0)" }.joined(separator: "; "))

            // What the alignment does to each single-marker decision of the model: class before -> after.
            var transitions: [String: Int] = [:]
            for i in items.indices {
                let o = outcomes[0][i]
                guard o.steps.count == 1, let gold = SpanEval.gold(items[i]), gold.solvable else { continue }
                let step = o.steps[0]
                let query = SpanSelect.Query(
                    words: SpanSelect.words(items[i].raw), marker: step.marker, window: step.window,
                    polish: Language.dominant(in: items[i].raw) == .polish)
                let aligned = SpanSelect.align(step.decision, in: query)
                guard aligned != step.decision else { continue }
                let before = SpanEval.classify(step.decision, against: gold, marker: step.marker)
                let after = SpanEval.classify(aligned, against: gold, marker: step.marker)
                transitions[
                    "\(items[i].isProbe ? "probes" : "corpus") \(before.rawValue)->\(after.rawValue)", default: 0] +=
                    1
            }
            print(
                "[span-\(label) N=\(limit)] alignment changes (model decisions): "
                    + transitions.keys.sorted().map { "\($0) \(transitions[$0] ?? 0)" }.joined(separator: "; "))

            let seconds = fresh.map(\.seconds)
            print(
                "[span-\(label) N=\(limit)] calls \(fresh.count) invalid answers \(invalid)"
                    + String(
                        format:
                            " latency \(reuse ? "warm-prefix" : "no-cache") p50 %.3fs p95 %.3fs mean decoded tokens %.0f of %.0f prompt tokens;"
                            + " peak RSS %.0f MB",
                        Self.percentile(seconds, 0.5), Self.percentile(seconds, 0.95),
                        Double(fresh.map(\.decodedTokens).reduce(0, +)) / Double(max(1, fresh.count)),
                        Double(fresh.map(\.promptTokens).reduce(0, +)) / Double(max(1, fresh.count)),
                        Self.peakResidentMegabytes()))

            var e2e: [String: [String: String]] = [:]
            if environment["LINTEL_SPAN_E2E"] != nil {
                var baseline: [(SpanEval.Item, String)] = []
                var reasons: [String: Int] = [:]
                var passIfAccepted = 0
                var rejectedButRight: [String] = []
                for i in corpusIndices {
                    let cleaned = try clean(items[i].raw)
                    baseline.append((items[i], cleaned.text))
                    reasons[cleaned.verdict, default: 0] += 1
                    let answerPasses = AutocorrectCorpus.satisfies(cleaned.model, items[i].corpus!)
                    if answerPasses { passIfAccepted += 1 }
                    if cleaned.verdict != "accepted", answerPasses { rejectedButRight.append(items[i].id) }
                    e2e[items[i].id, default: [:]]["main"] = cleaned.text
                }
                Self.printEndToEnd("[span-\(label) e2e N=\(limit)] main v1 (prompt 1 + main guard)", baseline)
                print(
                    "[span-\(label) e2e N=\(limit)] main v1 guard verdicts \(reasons.sorted { $0.key < $1.key })"
                        + " | the model's answer would pass if every answer were accepted: \(passIfAccepted)/\(corpusIndices.count)"
                        + " | rejected by main's guard although the answer passes: \(rejectedButRight.count) \(rejectedButRight.sorted())"
                )
                for (v, variant) in Self.variants.enumerated() where variant.name != "none" {
                    var texts: [(SpanEval.Item, String)] = []
                    for i in corpusIndices {
                        let text = try clean(outcomes[v][i].text).text
                        texts.append((items[i], text))
                        e2e[items[i].id, default: [:]][variant.name] = text
                    }
                    Self.printEndToEnd("[span-\(label) e2e N=\(limit)] span \(variant.name) + main v1 cleanup", texts)
                }
                print(
                    "[span-\(label) e2e] cleanup step latency p50 "
                        + String(
                            format: "%.2fs p95 %.2fs (%@)", Self.percentile(cleanSeconds, 0.5),
                            Self.percentile(cleanSeconds, 0.95), reuse ? "warm prefix" : "no cache"))
            }

            var rows: [[String: Any]] = []
            for i in items.indices {
                var row: [String: Any] = ["id": items[i].id]
                for (v, variant) in Self.variants.enumerated() {
                    row[variant.name] = [
                        "text": outcomes[v][i].text,
                        "decisions": outcomes[v][i].steps.map { "\($0.decision)" }.joined(separator: ","),
                    ]
                }
                if let cleaned = e2e[items[i].id] { row["e2e"] = cleaned }
                rows.append(row)
            }
            json["N\(limit)"] = rows
            json["N\(limit) answers"] = memo.mapValues { $0.answer }

            // Cold latency: no prefix reuse, on the first 40 distinct queries.
            if limit == limits.last {
                var cold: [Double] = []
                var coldTokens = 0
                var count = 0
                for item in items where count < 40 {
                    _ = try SpanSelect.run(item.raw, limit: limit, negationRule: false) { query in
                        count += 1
                        let answer = try runtime.answer(
                            messages: SpanSelect.messages(for: query).map { ($0.role, $0.content) },
                            grammar: SpanSelect.grammar(for: query.window), reuseCache: false)
                        cold.append(answer.seconds)
                        coldTokens += answer.decodedTokens
                        return .none
                    }
                }
                print(
                    "[span-\(label) N=\(limit)] "
                        + String(
                            format:
                                "latency cold (no prefix cache) over %d calls: p50 %.3fs p95 %.3fs, %.0f tokens decoded",
                            cold.count, Self.percentile(cold, 0.5), Self.percentile(cold, 0.95),
                            Double(coldTokens) / Double(max(1, cold.count))))

                // The product's order: one span call, then the cleanup of the same chunk, chunk after chunk. A
                // single KV sequence then holds the other prompt when the next span call comes.
                var interleaved: [Double] = []
                count = 0
                for item in items where count < 40 {
                    _ = try SpanSelect.run(item.raw, limit: limit, negationRule: false) { query in
                        count += 1
                        let answer = try runtime.answer(
                            messages: SpanSelect.messages(for: query).map { ($0.role, $0.content) },
                            grammar: SpanSelect.grammar(for: query.window), reuseCache: reuse)
                        interleaved.append(answer.seconds)
                        _ = try runtime.answer(
                            messages: MainPromptV1.messages(transcript: item.raw), grammar: nil, reuseCache: reuse,
                            maxTokens: 8)
                        return .none
                    }
                }
                print(
                    "[span-\(label) N=\(limit)] "
                        + String(
                            format: "latency interleaved with the cleanup prompt over %d calls: p50 %.3fs p95 %.3fs",
                            interleaved.count, Self.percentile(interleaved, 0.5), Self.percentile(interleaved, 0.95)))
            }
        }
        json["clean"] = cleanMemo.mapValues { ["text": $0.text, "verdict": $0.verdict] }
        if let directory = environment["LINTEL_SPAN_OUT"] {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: directory).appending(path: "\(label).json"))
        }
    }
}
