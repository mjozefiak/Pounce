import Foundation
import LintelKit
import LintelSpeech
import Synchronization

@testable import LintelProviders
@testable import MeetingsPlugin

/// A fake provider process: counts the starts that carry content, keeps what each one was given, and answers with
/// a closure. Nothing real starts (the runner gets `ProviderSystem` over this process and a fake locator).
final class CountingProviderProcess: ProviderProcessRunning, @unchecked Sendable {
    typealias Handler = @Sendable (_ call: Int, _ spec: ProviderProcessSpec) async throws -> ProviderProcessOutput

    private let state = Mutex((specs: [ProviderProcessSpec](), probes: 0))
    private let handler: Handler

    init(handler: @escaping Handler) { self.handler = handler }

    /// Answers every request with this notes draft.
    convenience init(answer: String = ProviderFixtures.draft) {
        self.init { _, _ in ProviderFixtures.output(answer: answer) }
    }

    var contentRuns: Int { state.withLock { $0.specs.count } }
    var probeRuns: Int { state.withLock { $0.probes } }
    var specs: [ProviderProcessSpec] { state.withLock { $0.specs } }

    func runContent(_ spec: ProviderProcessSpec) async throws -> ProviderProcessOutput {
        let call = state.withLock { state -> Int in
            state.specs.append(spec)
            return state.specs.count
        }
        return try await handler(call, spec)
    }

    func runProbe(_ spec: ProviderProcessSpec) async throws -> ProviderProcessOutput {
        state.withLock { $0.probes += 1 }
        return ProviderFixtures.output(answer: "ok")
    }
}

enum ProviderFixtures {
    /// A draft the fact guard keeps for `NotesFixtures.meeting()`.
    static let draft = """
        TITLE: Budżet marketingowy
        SUMMARY: Omówiono budżet na marketing i ofertę dla klienta.
        """

    static func output(answer: String, isError: Bool = false, modelUsage: [String: Any]? = nil)
        -> ProviderProcessOutput
    {
        var payload: [String: Any] = ["type": "result", "is_error": isError, "result": answer]
        if let modelUsage { payload["modelUsage"] = modelUsage }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return ProviderProcessOutput(stdout: data, stderr: Data(), exitCode: 0, ending: .exited)
    }

    /// A runner whose descriptor passed the isolation canary, over `process`. The app's own descriptor has not
    /// (`isolationVerified == false`), so the real runner starts nothing yet.
    static func runner(
        _ process: CountingProviderProcess, verified: Bool = true, gate: ProviderGate = .shared
    ) -> ProviderRunner {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "provider-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ProviderRunner(
            system: ProviderSystem(locator: QuietProviderLocator(), process: process),
            descriptors: [ProviderDescriptor.claudeCode.with(isolationVerified: verified)],
            cachesDirectory: directory, gate: gate)
    }

    /// The settings that choose Claude Code with a model, as the DEBUG `--qa-setting` flag would write them.
    static let chosen: [String: SettingValue] = [
        "plugins.meetings.notesEnabled": .bool(true),
        "plugins.meetings.notesProvider": .string("claude-code"),
        "plugins.meetings.notesProviderModel": .string("sonnet"),
    ]
}
