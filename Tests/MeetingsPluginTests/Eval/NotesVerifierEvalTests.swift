import Foundation
import LintelSpeech
import Testing

@testable import MeetingsPlugin

/// The offline measurement of `LLMNotesVerifier` on hand-labelled points (spec
/// `2026-11-06-meeting-notes-semantic-verifier`, A.2). Off unless all three inputs are set:
///
///     LINTEL_NOTES_VERIFIER_EVAL_MODEL=<model>.gguf LINTEL_NOTES_VERIFIER_EVAL_SAMPLE=sample.json \
///     LINTEL_NOTES_VERIFIER_EVAL_LABELS=labels.txt LINTEL_NOTES_VERIFIER_EVAL_OUT=/tmp/out \
///     swift test --filter NotesVerifierEvalTests
///
/// The sample (`{"sample": [{id, kind, text, quote, ctx: ["[idx] speaker: text", …]}, …]}`) and the labels
/// (`S01 F` per line: F faithful, M minor drift, W wrong) hold meeting text and stay outside the repository. The
/// test prints and writes item ids, labels and verdicts only, never text. Optional `_ATTEMPT` names the result
/// file (`<attempt>.json`, default `verifier-v<prompt version>`).
@Suite(
    .serialized,
    .enabled(
        if: ["MODEL", "SAMPLE", "LABELS"].allSatisfy {
            !(ProcessInfo.processInfo.environment["LINTEL_NOTES_VERIFIER_EVAL_\($0)"] ?? "").isEmpty
        }))
struct NotesVerifierEvalTests {
    private static func value(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment["LINTEL_NOTES_VERIFIER_EVAL_\(key)"]
        return (value?.isEmpty ?? true) ? nil : value
    }

    struct Sample: Decodable {
        struct Item: Decodable {
            var id: String
            var kind: String
            var text: String
            var quote: String
            var ctx: [String]
            var outcome: String?
        }
        var sample: [Item]
    }

    struct Result: Codable {
        struct Item: Codable {
            var id: String
            var label: String
            var kind: String
            var guardOutcome: String?
            var verdict: String
            var source: String
        }
        struct Gate: Codable {
            var faithfulSupported: Int
            var faithfulTotal: Int
            var wrongCaught: Int
            var wrongTotal: Int
            var minorCaught: Int
            var minorTotal: Int
            var passed: Bool
        }
        var schema = 1
        var attempt: String
        var promptVersion: Int
        var model: String
        var seconds: Double
        /// `confusion[label][verdict]`, labels F/M/W, verdicts supported/weaker/unsupported.
        var confusion: [String: [String: Int]]
        var sources: [String: Int]
        var gate: Gate
        var items: [Item]
    }

    /// `[15] Nadia: text` → speaker and text; the index is dropped.
    static func line(_ raw: String) -> NotesVerificationRequest.Line? {
        guard let match = raw.wholeMatch(of: /\[\d+\] ([^:]+): (.*)/) else { return nil }
        return .init(speaker: String(match.1), text: String(match.2))
    }

    static func kind(_ code: String) -> NotesPointKind? {
        code == "Q" ? .question : NotesPointKind(rawValue: code)
    }

    static func labels(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 2, ["F", "M", "W"].contains(fields[1]) else { continue }
            result[String(fields[0])] = String(fields[1])
        }
        return result
    }

    static func gate(_ confusion: [String: [String: Int]]) -> Result.Gate {
        func count(_ label: String, _ verdicts: [NotesVerdict]) -> Int {
            verdicts.reduce(0) { $0 + (confusion[label]?[$1.rawValue] ?? 0) }
        }
        let all = NotesVerdict.allCases
        let faithful = count("F", [.supported])
        let faithfulTotal = count("F", all)
        let wrong = count("W", [.weaker, .unsupported])
        let wrongTotal = count("W", all)
        let minor = count("M", [.weaker, .unsupported])
        let minorTotal = count("M", all)
        let passed =
            faithfulTotal > 0 && Double(faithful) >= 0.7 * Double(faithfulTotal) && wrongTotal > 0
            && wrong * 3 >= wrongTotal * 2 && minor * 2 >= minorTotal
        return .init(
            faithfulSupported: faithful, faithfulTotal: faithfulTotal, wrongCaught: wrong, wrongTotal: wrongTotal,
            minorCaught: minor, minorTotal: minorTotal, passed: passed)
    }

    @Test func evaluatesTheVerifierOnLabelledPoints() async throws {
        let modelURL = URL(filePath: try #require(Self.value("MODEL")))
        let sampleData = try Data(contentsOf: URL(filePath: try #require(Self.value("SAMPLE"))))
        let labelText = try String(contentsOf: URL(filePath: try #require(Self.value("LABELS"))), encoding: .utf8)
        let items = try JSONDecoder().decode(Sample.self, from: sampleData).sample
        let labels = Self.labels(labelText)
        try #require(Set(items.map(\.id)) == Set(labels.keys), "sample ids and label ids differ")

        let runtime = LlamaRuntime(contextLength: 4096)
        try await runtime.load(modelAt: modelURL)
        let verifier = LLMNotesVerifier(runtime: runtime)
        let clock = ContinuousClock()
        let started = clock.now
        var confusion: [String: [String: Int]] = [:]
        var sources: [String: Int] = [:]
        var results: [Result.Item] = []
        for item in items.sorted(by: { $0.id < $1.id }) {
            let label = labels[item.id] ?? "?"
            guard let kind = Self.kind(item.kind) else {
                Issue.record("\(item.id): unknown kind")
                continue
            }
            let context = item.ctx.compactMap(Self.line)
            if context.count != item.ctx.count { Issue.record("\(item.id): unparsed context line") }
            let request = NotesVerificationRequest(kind: kind, text: item.text, quote: item.quote, context: context)
            let verification = await verifier.verification(request)
            confusion[label, default: [:]][verification.verdict.rawValue, default: 0] += 1
            sources[verification.source.rawValue, default: 0] += 1
            results.append(
                .init(
                    id: item.id, label: label, kind: item.kind, guardOutcome: item.outcome,
                    verdict: verification.verdict.rawValue, source: verification.source.rawValue))
            print("VERIFIER-EVAL \(item.id) \(label) \(verification.verdict.rawValue) \(verification.source.rawValue)")
        }
        await runtime.unload()
        for _ in 0..<100 where await runtime.isLoaded { try? await Task.sleep(for: .milliseconds(50)) }
        let elapsed = clock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        let gate = Self.gate(confusion)
        print("VERIFIER-EVAL label  supported  weaker  unsupported")
        for label in ["F", "M", "W"] {
            let row = NotesVerdict.allCases.map { String(confusion[label]?[$0.rawValue] ?? 0) }
            print("VERIFIER-EVAL \(label)      \(row.joined(separator: "  "))")
        }
        print(
            "VERIFIER-EVAL gate F supported \(gate.faithfulSupported)/\(gate.faithfulTotal), W caught "
                + "\(gate.wrongCaught)/\(gate.wrongTotal), M caught \(gate.minorCaught)/\(gate.minorTotal), "
                + "passed=\(gate.passed) sources=\(sources.sorted { $0.key < $1.key }) seconds="
                + String(format: "%.1f", seconds))

        if let out = Self.value("OUT") {
            let attempt = Self.value("ATTEMPT") ?? "verifier-v\(NotesVerifierPrompt.version)"
            let result = Result(
                attempt: attempt, promptVersion: NotesVerifierPrompt.version, model: modelURL.lastPathComponent,
                seconds: seconds, confusion: confusion, sources: sources, gate: gate, items: results)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            let directory = URL(filePath: out, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "\(attempt).json")
            try encoder.encode(result).write(to: url, options: .atomic)
            print("VERIFIER-EVAL wrote \(url.path)")
        }
    }
}

/// The gate arithmetic runs in every test run; the measurement above needs the model and the labels.
@Suite struct NotesVerifierEvalGateTests {
    @Test func gateCountsMatchTheSpec() {
        let passing = [
            "F": ["supported": 28, "weaker": 12], "W": ["unsupported": 2, "supported": 1],
            "M": ["weaker": 9, "supported": 8],
        ]
        #expect(NotesVerifierEvalTests.gate(passing).passed)
        var failing = passing
        failing["F"] = ["supported": 27, "weaker": 13]
        #expect(!NotesVerifierEvalTests.gate(failing).passed)
        failing = passing
        failing["M"] = ["weaker": 8, "supported": 9]
        #expect(!NotesVerifierEvalTests.gate(failing).passed)
    }
}
