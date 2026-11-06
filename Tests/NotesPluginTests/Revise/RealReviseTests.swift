import Darwin
import Foundation
import LintelSpeech
import Testing

@testable import NotesPlugin

/// Runs the revise prompt and guard on a REAL model. Off by default: it needs a GGUF file from `LLMModelCatalog` and
/// takes minutes. Never run in CI.
///
///     LINTEL_REVISE_LLM_MODEL=/path/to/Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
///       swift test -c release --filter RealReviseTests
///
/// It asserts only what must hold for any model (`ReviseInvariants`: nothing outside the commented blocks changes, no
/// image, link or HTML the note did not have, no bait text from the corpus) and prints `REVISE-BENCH` lines with the
/// time, the model's answer size and the guard's verdict counts. A refused run is a valid outcome and is reported, not
/// failed. No note text, comment or answer is printed.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LINTEL_REVISE_LLM_MODEL"] != nil), .serialized)
struct RealReviseTests {
    private static var modelURL: URL? {
        ProcessInfo.processInfo.environment["LINTEL_REVISE_LLM_MODEL"].map { URL(filePath: $0) }
    }

    private static func footprintMB() -> Int {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        return status == 0 ? Int(info.ri_phys_footprint / 1_048_576) : 0
    }

    @Test func theCorpusOnARealModel() async throws {
        let url = try #require(Self.modelURL)
        let model = LeasedReviseModel(lease: LLMLease(), modelURL: url, keepWarm: { .seconds(1) })
        let handle = try await model.acquire()
        defer { Task { await handle.release() } }
        for corpus in try ReviseCorpusCase.all() {
            let plan = try corpus.plan()
            guard !plan.units.isEmpty else { continue }
            let messages = ReviseNotesPrompt.messages(units: plan.units)
            let maxTokens = ReviseNotesPrompt.maxTokens(units: plan.units, contextLength: ReviseModelKey.contextLength)
            let clock = ContinuousClock()
            var answer: GenerationResult?
            let elapsed = try await clock.measure {
                answer = try await handle.generate(messages: messages, maxTokens: maxTokens)
            }
            let generated = try #require(answer)
            var outcome = "refused"
            var counts = "applied=0 rejected=0 unchanged=0 skipped=0"
            if !generated.stoppedByTokenLimit,
                let verdict = try? ReviseGuard.check(head: corpus.note, plan: plan, answer: generated.text)
            {
                outcome = verdict.applied.isEmpty ? "nothing" : "applied"
                counts =
                    "applied=\(verdict.applied.count) rejected=\(verdict.rejected.count) unchanged=\(verdict.unchanged.count) skipped=\(verdict.skipped.count)"
                ReviseInvariants.check(note: corpus.note, plan: plan, verdict: verdict, context: corpus.name)
                for text in corpus.expect.drop where !corpus.note.contains(text) {
                    #expect(!verdict.body.contains(text), "\(corpus.name): \(text) got into the note")
                }
            }
            print(
                "REVISE-BENCH name=\(corpus.name) units=\(plan.units.count) answerChars=\(generated.text.count) cutOff=\(generated.stoppedByTokenLimit) outcome=\(outcome) \(counts) seconds=\(String(format: "%.1f", elapsed.seconds)) footprintMB=\(Self.footprintMB())"
            )
        }
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
