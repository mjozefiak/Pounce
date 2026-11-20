import Foundation
import Testing

@testable import DictationPlugin

/// Real-model measurement of span selection (off by default, like the other real-model harnesses; never run
/// in CI). Run it alone, once per model:
/// `LINTEL_SPAN_MODEL=<gguf> LINTEL_SPAN_LABEL=<name> LINTEL_SPAN_NS=4,8,12 swift test --filter RealSpanSelectTests`.
/// Prints counts and invented ids only; `LINTEL_SPAN_OUT=<dir>` also writes the decisions as JSON there.
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

    /// The counts of the real-model corpus test of PR 134, for texts that came out of some pipeline.
    static func printEndToEnd(_ tag: String, _ texts: [(SpanEval.Item, String)]) {
        var passed = 0
        var withdrawalPassed = 0
        var withdrawals = 0
        var negativePassed = 0
        var negatives = 0
        var lostFinal: [String] = []
        var keptWithdrawn: [String] = []
        var both: [String] = []
        var changedNegation: [String] = []
        var overRemoved: [String] = []
        for (item, text) in texts {
            guard let corpus = item.corpus else { continue }
            let ok = AutocorrectCorpus.satisfies(text, corpus)
            if ok { passed += 1 }
            let words = Set(AutocorrectCorpus.tokens(text))
            let polish = Language.dominant(in: item.raw) == .polish
            if AutocorrectCorpus.withdrawing.contains(item.category) {
                withdrawals += 1
                if ok { withdrawalPassed += 1 }
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
                + " negatives \(negativePassed)/\(negatives) | lostFinal \(lostFinal.count) \(lostFinal.sorted())"
                + " keptWithdrawn \(keptWithdrawn.count) bothVersions \(both.count) \(both.sorted())"
                + " changedNegation \(changedNegation.count) \(changedNegation.sorted())"
                + " overRemovedNegatives \(overRemoved.count) \(overRemoved.sorted())")
    }

    static func peakResidentMegabytes() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINTEL_SPAN_MODEL"] != nil))
    func measure() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["LINTEL_SPAN_MODEL"])
        let label = environment["LINTEL_SPAN_LABEL"] ?? "model"
        let limits = (environment["LINTEL_SPAN_NS"] ?? "8").split(separator: ",").compactMap { Int($0) }
        let loadStart = ContinuousClock.now
        let runtime = try SpanLlama(path: path)
        let load = ContinuousClock.now - loadStart
        print("[span-\(label)] load \(load)")
        let items = try SpanEval.items()

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
                    reuseCache: true)
                let parsed = SpanSelect.parse(answer.text, window: query.window)
                if !parsed.valid { invalid += 1 }
                let call = Call(
                    decision: parsed.decision, valid: parsed.valid, answer: answer.text, seconds: answer.seconds,
                    promptTokens: answer.promptTokens, decodedTokens: answer.decodedTokens)
                memo[key] = call
                fresh.append(call)
                return call.decision
            }

            struct Result {
                let item: SpanEval.Item
                let plain: SpanSelect.Outcome
                let ruled: SpanSelect.Outcome
            }
            var results: [Result] = []
            for item in items {
                let plain = try SpanSelect.run(item.raw, limit: limit, negationRule: false, decide: decide)
                let ruled = try SpanSelect.run(item.raw, limit: limit, negationRule: true, decide: decide)
                results.append(Result(item: item, plain: plain, ruled: ruled))
            }

            for rule in [false, true] {
                let tag = "[span-\(label) N=\(limit) rule=\(rule ? "on" : "off")]"
                func outcome(_ r: Result) -> SpanSelect.Outcome { rule ? r.ruled : r.plain }
                let corpus = results.filter { !$0.item.isProbe }
                let withdrawals = corpus.filter { AutocorrectCorpus.withdrawing.contains($0.item.category) }
                let negatives = corpus.filter { $0.item.isNegative }
                func passes(_ r: Result) -> Bool { SpanEval.quality(outcome(r).text, of: r.item)?.passes ?? false }

                let withdrawalIDs = Set(withdrawals.map(\.item.id))
                let others = corpus.filter { !withdrawalIDs.contains($0.item.id) && !$0.item.isNegative }
                print(
                    "\(tag) corpus pass \(corpus.filter(passes).count)/\(corpus.count)"
                        + " withdrawals \(withdrawals.filter(passes).count)/\(withdrawals.count)"
                        + " negatives \(negatives.filter(passes).count)/\(negatives.count)"
                        + " falsestart+filler \(others.filter(passes).count)/\(others.count)"
                        + " (the cleanup step after the cut is not applied here)")
                print(
                    "\(tag) withdrawals failing: \(withdrawals.filter { !passes($0) }.map(\.item.id).sorted())")
                print(
                    "\(tag) negatives changed (false alarms): "
                        + "\(negatives.filter { outcome($0).text != $0.item.raw }.map(\.item.id).sorted())"
                        + " called \(negatives.filter { outcome($0).calls > 0 }.count)/\(negatives.count)")

                // Start accuracy on the single-marker items with a gold decision.
                var classes: [String: [SpanEval.Class: [String]]] = [:]
                for r in results {
                    let o = outcome(r)
                    guard o.steps.count == 1, let gold = SpanEval.gold(r.item), gold.solvable else { continue }
                    let kind = r.item.isProbe ? "probes" : (r.item.isNegative ? "negatives" : "corpus withdrawals")
                    guard !(kind == "corpus withdrawals" && !AutocorrectCorpus.withdrawing.contains(r.item.category))
                    else { continue }
                    let step = o.steps[0]
                    let cls = SpanEval.classify(step.decision, against: gold, marker: step.marker)
                    classes[kind, default: [:]][cls, default: []].append(r.item.id)
                }
                for kind in classes.keys.sorted() {
                    let counts = SpanEval.Class.allCases.compactMap { cls -> String? in
                        guard let ids = classes[kind]?[cls] else { return nil }
                        return "\(cls.rawValue) \(ids.count)"
                    }
                    let total = classes[kind]?.values.map(\.count).reduce(0, +) ?? 0
                    print("\(tag) start accuracy \(kind) (n=\(total)): " + counts.joined(separator: ", "))
                    if kind == "corpus withdrawals" {
                        for cls in [SpanEval.Class.wrong, .offByOneLong, .offByOneShort, .missed] {
                            if let ids = classes[kind]?[cls] { print("\(tag)   \(cls.rawValue): \(ids.sorted())") }
                        }
                    }
                }

                // Harm in the final texts of labeled items.
                var overRemoved: [String] = []
                var negationLost: [String] = []
                var probeFalseAlarms: [String] = []
                for r in results where !r.item.refs.isEmpty {
                    let text = outcome(r).text
                    guard let quality = SpanEval.quality(text, of: r.item) else { continue }
                    if !quality.lost.isEmpty { overRemoved.append(r.item.id) }
                    if quality.negationLost { negationLost.append(r.item.id) }
                    if r.item.isProbe, let gold = SpanEval.gold(r.item), gold.decision == .none, text != r.item.raw {
                        probeFalseAlarms.append(r.item.id)
                    }
                }
                print(
                    "\(tag) final texts over-removed (lost a reference word) \(overRemoved.count) \(overRemoved.sorted())"
                        + " | negation lost \(negationLost.count) \(negationLost.sorted())"
                        + " | probe false alarms \(probeFalseAlarms.count) \(probeFalseAlarms.sorted())")

                let badHits = results.filter { r in
                    r.item.bads.contains { SpanEval.tokens($0) == SpanEval.tokens(outcome(r).text) }
                }.map(\.item.id)
                var negationDropped: [String] = []
                for r in results where r.item.refs.isEmpty && r.item.isProbe {
                    let o = outcome(r)
                    let polish = Language.dominant(in: r.item.raw) == .polish
                    let markerNegations = o.steps.filter { $0.decision != .none }
                        .map { SpanEval.negations($0.markerKeys, polish: polish) }.reduce(0, +)
                    let dropped =
                        SpanEval.negations(SpanEval.tokens(r.item.raw), polish: polish)
                        - SpanEval.negations(SpanEval.tokens(o.text), polish: polish) - markerNegations
                    if dropped > 0 { negationDropped.append(r.item.id) }
                }
                print(
                    "\(tag) result equals a reviewer's known-bad output: \(badHits.count) \(badHits.sorted())"
                        + " | unlabeled probes that lose a negation outside the marker: "
                        + "\(negationDropped.count) \(negationDropped.sorted())")

                let labeledProbes = results.filter { $0.item.isProbe && !$0.item.refs.isEmpty }
                let unlabeled = results.filter { $0.item.isProbe && $0.item.refs.isEmpty }
                let changed = unlabeled.filter { outcome($0).text != $0.item.raw }
                print(
                    "\(tag) probes labeled pass \(labeledProbes.filter(passes).count)/\(labeledProbes.count)"
                        + " | unlabeled probes: called \(unlabeled.filter { outcome($0).calls > 0 }.count)/\(unlabeled.count),"
                        + " cut \(changed.count) \(changed.map(\.item.id).sorted())")
            }

            let seconds = fresh.map(\.seconds)
            print(
                "[span-\(label) N=\(limit)] calls \(fresh.count) invalid answers \(invalid)"
                    + String(
                        format:
                            " latency warm-prefix p50 %.3fs p95 %.3fs mean decoded tokens %.0f of %.0f prompt tokens;"
                            + " peak RSS %.0f MB",
                        Self.percentile(seconds, 0.5), Self.percentile(seconds, 0.95),
                        Double(fresh.map(\.decodedTokens).reduce(0, +)) / Double(max(1, fresh.count)),
                        Double(fresh.map(\.promptTokens).reduce(0, +)) / Double(max(1, fresh.count)),
                        Self.peakResidentMegabytes()))

            if environment["LINTEL_SPAN_E2E"] != nil,
                limit == (Int(environment["LINTEL_SPAN_E2E_N"] ?? "") ?? limits[0])
            {
                func clean(_ text: String) throws -> String {
                    let words = FormatterGuard.words(in: text)
                    let answer = try runtime.answer(
                        messages: MainPromptV1.messages(transcript: text), grammar: nil, reuseCache: true,
                        maxTokens: words * 4 + 64)
                    if case .accepted(let cleaned) = MainGuardReference.check(input: text, output: answer.text) {
                        return cleaned
                    }
                    return text
                }
                let corpus = results.filter { !$0.item.isProbe }
                var baseline: [(SpanEval.Item, String)] = []
                var spanned: [(SpanEval.Item, String)] = []
                var baselineSeconds: [Double] = []
                var spanSeconds: [Double] = []
                for r in corpus {
                    var started = ContinuousClock.now
                    baseline.append((r.item, try clean(r.item.raw)))
                    baselineSeconds.append(Self.seconds(ContinuousClock.now - started))
                    started = ContinuousClock.now
                    spanned.append((r.item, try clean(r.ruled.text)))
                    spanSeconds.append(Self.seconds(ContinuousClock.now - started))
                }
                for (name, texts, seconds) in [
                    ("main v1 (prompt 1 + main guard)", baseline, baselineSeconds),
                    ("span cut (N=\(limit), rule on) + main v1 cleanup", spanned, spanSeconds),
                ] {
                    Self.printEndToEnd("[span-\(label) e2e] \(name)", texts)
                    print(
                        "[span-\(label) e2e] \(name) cleanup step latency (second step only, warm) p50 "
                            + String(
                                format: "%.2fs p95 %.2fs", Self.percentile(seconds, 0.5), Self.percentile(seconds, 0.95)
                            ))
                }
            }
            if let directory = environment["LINTEL_SPAN_OUT"] {
                var rows: [[String: String]] = []
                for r in results {
                    rows.append([
                        "id": r.item.id, "plain": r.plain.text,
                        "decisions": r.plain.steps.map { "\($0.decision)" }.joined(separator: ","),
                    ])
                }
                let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
                try data.write(to: URL(fileURLWithPath: directory).appending(path: "\(label)-N\(limit).json"))
            }

            // Cold latency: no prefix reuse, on the first 40 distinct queries.
            if limit == limits.last {
                var cold: [Double] = []
                var coldTokens = 0
                var count = 0
                for r in results where count < 40 {
                    _ = try SpanSelect.run(r.item.raw, limit: limit, negationRule: false) { query in
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
            }
        }
    }
}
