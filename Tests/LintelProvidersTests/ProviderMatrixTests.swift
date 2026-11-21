import Foundation
import LintelSpeech
import Testing

@testable import LintelProviders

/// Rows of the "0 processes without consent" matrix that belong to this target (spec: matrix, rows 1-8, 11, 11a-11c,
/// 13-14 and 27 at the level of the runner). They count starts of the content process on the quiet system.
@Suite struct ProviderMatrixTests {
    private func runner(
        _ process: QuietProviderProcess, verified: Bool = true, descriptor: ProviderDescriptor? = nil
    ) -> ProviderRunner {
        let base = descriptor ?? ProviderDescriptor.claudeCode
        return ProviderRunner(
            system: .quiet(process), descriptors: [base.with(isolationVerified: verified)],
            cachesDirectory: URL(filePath: NSTemporaryDirectory()).appending(
                path: "providers-matrix-\(UUID().uuidString)"),
            gate: ProviderGate())
    }

    private func descriptor(argv: @escaping @Sendable (String, String) throws -> [String]) -> ProviderDescriptor {
        let d = ProviderDescriptor.claudeCode
        return ProviderDescriptor(
            id: d.id, recipient: d.recipient, displayName: d.displayName, binaryNames: d.binaryNames,
            versionArguments: d.versionArguments, authStatusArguments: d.authStatusArguments,
            supportedVersions: d.supportedVersions, models: d.models, isolationVerified: true,
            environmentAllowlist: d.environmentAllowlist, argumentBuilder: argv)
    }

    @Test(arguments: [
        ProviderDenial.noConsent, .outdatedConsent, .otherProvider, .otherModel, .withdrawn, .featureOff,
    ])
    func aRefusalMeansZeroProcesses(reason: ProviderDenial) async {
        let process = QuietProviderProcess()
        await #expect(throws: ProviderError.notAuthorized(reason)) {
            try await runner(process).run(makeRequest(), authorization: { .denied(reason) })
        }
        #expect(process.contentRuns == 0)
        #expect(process.probeRuns == 0)
    }

    @Test func anUnverifiedDescriptorMeansZeroProcesses() async {
        let process = QuietProviderProcess()
        let counter = LockedCounter()
        await #expect(throws: ProviderError.isolationNotVerified) {
            try await runner(process, verified: false).run(
                makeRequest(),
                authorization: {
                    counter.increment()
                    return .allowed
                })
        }
        #expect(process.contentRuns == 0)
        #expect(counter.value == 0, "no point asking for consent when nothing may start")
        #expect(await runner(process, verified: false).tryOut(provider: .claudeCode, model: "sonnet") == .unavailable)
        #expect(process.probeRuns == 0)
    }

    @Test func theShippedDescriptorStartsAfterAuthorization() async throws {
        let process = QuietProviderProcess()
        let shipped = ProviderRunner(
            system: .quiet(process),
            cachesDirectory: URL(filePath: NSTemporaryDirectory()).appending(path: "x-\(UUID())"))
        _ = try await shipped.run(makeRequest(), authorization: allowed)
        #expect(process.contentRuns == 1)
        do {
            _ = try await shipped.run(makeRequest(), authorization: { .denied(.noConsent) })
            Issue.record("a denied authorization must not run")
        } catch ProviderError.notAuthorized {}
        #expect(process.contentRuns == 1, "a denied authorization still starts nothing")
    }

    @Test(arguments: [
        "--setting-sources", "--strict-mcp-config", "--no-session-persistence", "--tools", "--disable-slash-commands",
        "--safe-mode",
    ])
    func anArgvWithoutARequirementMeansZeroProcesses(missing: String) async throws {
        let process = QuietProviderProcess()
        let broken = descriptor { model, prompt in
            var argv = try ProviderDescriptor.claudeArguments(model: model, systemPrompt: prompt)
            let index = argv.firstIndex(of: missing)!
            let width = (missing == "--setting-sources" || missing == "--tools") ? 2 : 1
            argv.removeSubrange(index..<(index + width))
            return argv
        }
        await #expect(throws: ProviderError.isolationProblem(["missing:\(missing)"])) {
            try await runner(process, descriptor: broken).run(makeRequest(), authorization: allowed)
        }
        #expect(process.contentRuns == 0)
    }

    @Test func aNonEmptySettingSourcesMeansZeroProcesses() async {
        let process = QuietProviderProcess()
        let broken = descriptor { model, prompt in
            var argv = try ProviderDescriptor.claudeArguments(model: model, systemPrompt: prompt)
            argv[argv.firstIndex(of: "--setting-sources")! + 1] = "user"
            return argv
        }
        await #expect(throws: ProviderError.isolationProblem(["value:--setting-sources"])) {
            try await runner(process, descriptor: broken).run(makeRequest(), authorization: allowed)
        }
        #expect(process.contentRuns == 0)
    }

    @Test(arguments: [
        "--settings", "--mcp-config", "--plugin-dir", "--plugin-url", "--add-dir", "--agents", "--continue", "--resume",
    ])
    func aForbiddenFlagMeansZeroProcesses(flag: String) async {
        let process = QuietProviderProcess()
        let broken = descriptor { model, prompt in
            try ProviderDescriptor.claudeArguments(model: model, systemPrompt: prompt) + [flag, "x"]
        }
        await #expect(throws: ProviderError.isolationProblem(["forbidden:\(flag)"])) {
            try await runner(process, descriptor: broken).run(makeRequest(), authorization: allowed)
        }
        #expect(process.contentRuns == 0)
    }

    @Test func aBadModelOrEmptyContentMeansZeroProcesses() async {
        let process = QuietProviderProcess()
        await #expect(throws: ProviderError.invalidModel) {
            try await runner(process).run(makeRequest(model: "a b; rm"), authorization: allowed)
        }
        let empty = ProviderRequest(
            feature: .meetingsNotes, model: "sonnet", messages: [ChatMessage(role: "system", content: "x")])
        await #expect(throws: ProviderError.invalidRequest) {
            try await runner(process).run(empty, authorization: allowed)
        }
        #expect(process.contentRuns == 0)
    }

    @Test func anUnknownProviderMeansZeroProcesses() async {
        let process = QuietProviderProcess()
        let request = ProviderRequest(
            provider: ProviderID(rawValue: "other"), feature: .meetingsNotes, model: "sonnet",
            messages: [ChatMessage(role: "user", content: "hi")])
        await #expect(throws: ProviderError.unsupportedProvider) {
            try await runner(process).run(request, authorization: allowed)
        }
        #expect(process.contentRuns == 0)
    }

    @Test func aValidRequestStartsExactlyOneProcess() async throws {
        let process = QuietProviderProcess(response: #"{"is_error":false,"result":"done"}"#)
        let result = try await runner(process).run(makeRequest(), authorization: allowed)
        #expect(result.text == "done")
        #expect(process.contentRuns == 1)
        #expect(ProviderSystem.quiet(process).quietRuns === process)
    }

    @Test func authorizationIsAskedOncePerStartAndRevokedConsentStopsTheNextRun() async throws {
        let process = QuietProviderProcess()
        let asked = LockedCounter()
        let revoked = LockedCounter()
        let auth: ProviderAuthorization = {
            asked.increment()
            return revoked.value > 0 ? .denied(.withdrawn) : .allowed
        }
        let r = runner(process)
        _ = try await r.run(makeRequest(), authorization: auth)
        revoked.increment()
        await #expect(throws: ProviderError.notAuthorized(.withdrawn)) {
            try await r.run(makeRequest(), authorization: auth)
        }
        #expect(asked.value == 2)
        #expect(process.contentRuns == 1)
    }

    @Test func consentRevokedWhileWaitingInTheQueueStartsNothing() async throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let cli = try FakeCLI(in: temp.url, mode: "gated")
        let gate = ProviderGate()
        let live = makeRunner(cli, caches: temp.url.appending(path: "c"), gate: gate)
        let flag = LockedCounter()
        let first = Task { try await live.run(makeRequest(), authorization: allowed) }
        #expect(await eventually { !cli.read("argv").isEmpty })
        let second = Task {
            try await live.run(makeRequest(), authorization: { flag.value > 0 ? .denied(.withdrawn) : .allowed })
        }
        #expect(await eventuallyAsync { await gate.queuedCount == 1 })  // the second one waits behind the first
        flag.increment()
        cli.release()  // revoked while queued behind the first run
        _ = try await first.value
        await #expect(throws: ProviderError.notAuthorized(.withdrawn)) { try await second.value }
    }

    @Test func authorizationIsAskedAfterTheQueueNotBefore() async throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let cli = try FakeCLI(in: temp.url, mode: "gated")
        let gate = ProviderGate()
        let live = makeRunner(cli, caches: temp.url.appending(path: "c"), gate: gate)
        let times = TimeLog()
        let first = Task {
            try await live.run(
                makeRequest(),
                authorization: {
                    times.mark("a1")
                    return .allowed
                })
        }
        #expect(await eventually { !cli.read("argv").isEmpty })
        let second = Task {
            try await live.run(
                makeRequest(),
                authorization: {
                    times.mark("a2")
                    return .allowed
                })
        }
        #expect(await eventuallyAsync { await gate.queuedCount == 1 })
        #expect(times.at("a2") == nil, "the second authorization must wait until the first run left the gate")
        cli.release()
        _ = try await first.value
        _ = try await second.value
        #expect(times.at("a1") != nil)
        #expect(times.at("a2") != nil)
    }

    @Test func aQueuedRequestThatIsCancelledNeverAsksOrStarts() async throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let cli = try FakeCLI(in: temp.url, mode: "gated")
        let gate = ProviderGate()
        let live = makeRunner(cli, caches: temp.url.appending(path: "c"), gate: gate)
        let asked = LockedCounter()
        let first = Task { try await live.run(makeRequest(), authorization: allowed) }
        #expect(await eventually { !cli.read("argv").isEmpty })
        let second = Task {
            try await live.run(
                makeRequest(),
                authorization: {
                    asked.increment()
                    return .allowed
                })
        }
        #expect(await eventuallyAsync { await gate.queuedCount == 1 })
        second.cancel()
        await #expect(throws: (any Error).self) { try await second.value }
        cli.release()
        _ = try await first.value
        #expect(asked.value == 0)
    }

    @Test func theSingleRunBranchWithConsentRevokedDuringTheRunStopsTheRetry() async throws {
        // The one-process variant of rows 13/14/27: the run that is going on ends, the retry is refused.
        let temp = try TempDir()
        defer { temp.remove() }
        let cli = try FakeCLI(in: temp.url, mode: "exit3")
        let live = makeRunner(cli, caches: temp.url.appending(path: "c"), gate: ProviderGate())
        let revoked = LockedCounter()
        let auth: ProviderAuthorization = { revoked.value > 0 ? .denied(.withdrawn) : .allowed }
        await #expect(throws: ProviderError.failed(.other)) { try await live.run(makeRequest(), authorization: auth) }
        revoked.increment()
        cli.setMode("ok")
        await #expect(throws: ProviderError.notAuthorized(.withdrawn)) {
            try await live.run(makeRequest(), authorization: auth)
        }
        #expect(cli.read("argv").contains("--model"))  // only the first run ever started
        #expect(cli.read("stdin").contains(syntheticCanary))
    }

    @Test func theQuietSystemNeverBuildsARealProcess() {
        let system = ProviderSystem.quiet
        #expect(system.process is QuietProviderProcess)
        #expect(!(system.process is LiveProviderProcess))
        #expect(system.locator is QuietProviderLocator)
        #expect(system.quietRuns != nil)
    }
}

final class TimeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [String: Double] = [:]
    func mark(_ name: String) { lock.withLock { marks[name] = Date().timeIntervalSince1970 } }
    func at(_ name: String) -> Double? { lock.withLock { marks[name] } }
}
