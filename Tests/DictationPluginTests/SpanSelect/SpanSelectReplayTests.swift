import Foundation
import Testing

@testable import DictationPlugin

/// Replays the model's stored answers (the JSON that `RealSpanSelectTests` writes with `LINTEL_SPAN_OUT`)
/// through every rule set, without a model: a change of a deterministic rule is measured on the decisions
/// the model really gave. Off by default: `LINTEL_SPAN_REPLAY=<json>[,<json>...] swift test --filter
/// SpanSelectReplayTests`. A query the stored run never asked (a chain resolved differently) is answered
/// `none` and counted; a cut text whose cleanup is not stored is counted as missing in the end-to-end line.
@Suite struct SpanSelectReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINTEL_SPAN_REPLAY"] != nil))
    func replay() throws {
        let paths = (ProcessInfo.processInfo.environment["LINTEL_SPAN_REPLAY"] ?? "").split(separator: ",")
        let items = try SpanEval.items()
        for path in paths {
            let data = try Data(contentsOf: URL(fileURLWithPath: String(path)))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let label = (json["label"] as? String) ?? "run"
            let cleanups = (json["clean"] as? [String: [String: String]]) ?? [:]
            for key in json.keys.sorted() where key.hasPrefix("N") && key.hasSuffix(" answers") {
                guard let limit = Int(key.dropFirst().prefix { $0.isNumber }),
                    let answers = json[key] as? [String: String]
                else { continue }
                var unknown = 0
                func decide(_ query: SpanSelect.Query) -> SpanSelect.Decision {
                    guard let answer = answers["\(query.window)|" + SpanSelect.userMessage(query)] else {
                        unknown += 1
                        return .none
                    }
                    return SpanSelect.parse(answer, window: query.window).decision
                }
                for variant in RealSpanSelectTests.variants {
                    unknown = 0
                    let outcomes = items.map { item in
                        variant.fromEnd
                            ? SpanSelect.runFromEnd(item.raw, limit: limit, rules: variant.rules, decide: decide)
                            : SpanSelect.run(item.raw, limit: limit, rules: variant.rules, decide: decide)
                    }
                    let tag = "[replay-\(label) N=\(limit) \(variant.name)]"
                    RealSpanSelectTests.printCutMetrics(tag, items: items, outcomes: outcomes, limit: limit)
                    var texts: [(SpanEval.Item, String)] = []
                    var missing = 0
                    for (item, outcome) in zip(items, outcomes) where !item.isProbe {
                        if let cleaned = cleanups[outcome.text]?["text"] {
                            texts.append((item, cleaned))
                        } else {
                            missing += 1
                        }
                    }
                    print("\(tag) queries not in the stored run \(unknown), cleanups not stored \(missing)")
                    if missing == 0, variant.name != "none" {
                        RealSpanSelectTests.printEndToEnd("\(tag) e2e", texts)
                    }
                }
            }
        }
    }
}
