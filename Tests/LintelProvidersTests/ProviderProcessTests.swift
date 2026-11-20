import Foundation
import LintelSpeech
import Testing

@testable import LintelProviders

/// Runs a fake binary (a script in a temporary directory). Never the real `claude`, never the network.
@Suite struct ProviderProcessTests {
    private func setup(mode: String = "ok") throws -> (TempDir, FakeCLI, URL) {
        let temp = try TempDir()
        let cli = try FakeCLI(in: temp.url, mode: mode)
        return (temp, cli, temp.url.appending(path: "caches", directoryHint: .isDirectory))
    }

    @Test func aSuccessfulRunReturnsTheAnswer() async throws {
        let (temp, cli, caches) = try setup()
        defer { temp.remove() }
        let result = try await makeRunner(cli, caches: caches).run(makeRequest(), authorization: allowed)
        #expect(result == GenerationResult(text: "Fake answer.", stoppedByTokenLimit: false))
    }

    @Test func contentGoesToStdinNotArgv() async throws {
        let (temp, cli, caches) = try setup()
        defer { temp.remove() }
        _ = try await makeRunner(cli, caches: caches).run(makeRequest(), authorization: allowed)
        #expect(cli.read("stdin").contains(syntheticCanary))
        #expect(!cli.read("argv").contains(syntheticCanary))
        #expect(cli.read("argv").contains("Write short notes."))
    }

    @Test func theChildGetsEveryIsolationFlagAndNoForbiddenOne() async throws {
        let (temp, cli, caches) = try setup()
        defer { temp.remove() }
        _ = try await makeRunner(cli, caches: caches).run(makeRequest(), authorization: allowed)
        let argv = cli.lines("argv")
        #expect(ProviderDescriptor.claudeCode.isolationProblems(arguments: argv).isEmpty)
        for flag in ["--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands"] {
            #expect(argv.contains(flag))
        }
        #expect(argv[argv.firstIndex(of: "--setting-sources")! + 1] == "")
        #expect(argv[argv.firstIndex(of: "--tools")! + 1] == "")
        for forbidden in ProviderDescriptor.forbiddenFlags { #expect(!argv.contains(forbidden)) }
    }

    @Test func onlyAllowedVariablesReachTheChild() async throws {
        let (temp, cli, caches) = try setup()
        defer { temp.remove() }
        _ = try await makeRunner(cli, caches: caches).run(makeRequest(), authorization: allowed)
        let names = Set(cli.lines("envnames"))
        let allowedNames = Set(ProviderDescriptor.claudeCode.environmentAllowlist).union(["PATH"])
        // The shell adds a few of its own (`_`, `PWD`, `SHLVL`, `OLDPWD`).
        #expect(names.subtracting(allowedNames).subtracting(["_", "PWD", "SHLVL", "OLDPWD"]).isEmpty)
        for junk in [
            "CLAUDE_CODE_SOMETHING", "CLAUDECODE", "CLAUDE_FAKE_FLAG", "ANTHROPIC_MODEL", "ANTHROPIC_BASE_URL",
            "SECRET_TOKEN",
        ] {
            #expect(!names.contains(junk), "\(junk) must not reach the child")
        }
        #expect(cli.read("userenv").contains("USER=tester"))
        #expect(names.contains("CLAUDE_CONFIG_DIR"))
        #expect(names.contains("ANTHROPIC_API_KEY"))  // authentication variables pass unchanged
    }

    @Test func theWorkingDirectoryIsNewEmptyPrivateAndRemoved() async throws {
        let (temp, cli, caches) = try setup()
        defer { temp.remove() }
        _ = try await makeRunner(cli, caches: caches).run(makeRequest(), authorization: allowed)
        let cwd = cli.read("cwd").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(filePath: cwd).lastPathComponent.hasPrefix(ProviderWorkspace.prefix))
        #expect(cli.read("cwdlist").isEmpty)  // no .claude/, .mcp.json, CLAUDE.md
        #expect(cli.read("cwdmode").trimmingCharacters(in: .whitespacesAndNewlines) == "700")
        let left = try FileManager.default.contentsOfDirectory(atPath: caches.path)
        #expect(left.isEmpty)
    }

    @Test func noSessionFileIsLeftBehind() async throws {
        let (temp, cli, caches) = try setup()
        defer { temp.remove() }
        _ = try await makeRunner(cli, caches: caches).run(makeRequest(), authorization: allowed)
        let projects = cli.configDir.appending(path: "projects")
        #expect(!FileManager.default.fileExists(atPath: projects.path))
    }

    @Test func theFakeDoesWriteASessionWithoutTheFlag() async throws {
        // Control: proves the check above can fail. The fake records a session only without the flag.
        let (temp, cli, caches) = try setup()
        defer { temp.remove() }
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let spec = ProviderProcessSpec(
            executable: cli.script, arguments: ["-p"],
            environment: cli.sourceEnvironment().filter { $0.key == "CLAUDE_CONFIG_DIR" },
            workingDirectory: caches, stdin: Data(syntheticCanary.utf8), timeout: .seconds(10))
        _ = try await LiveProviderProcess().runProbe(spec)
        #expect(cli.configDir.appending(path: "projects/p/s.jsonl").path.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: cli.configDir.appending(path: "projects/p/s.jsonl").path))
    }

    @Test func aTimeoutEndsTheRunAndKillsTheChild() async throws {
        let (temp, cli, caches) = try setup(mode: "hang")
        defer { temp.remove() }
        let started = Date()
        await #expect(throws: ProviderError.timedOut) {
            try await makeRunner(cli, caches: caches).run(
                makeRequest(timeout: .milliseconds(500)), authorization: allowed)
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func tooMuchOutputEndsTheRun() async throws {
        let (temp, cli, caches) = try setup(mode: "bigout")
        defer { temp.remove() }
        await #expect(throws: ProviderError.outputTooLarge) {
            try await makeRunner(cli, caches: caches).run(makeRequest(), authorization: allowed)
        }
    }

    @Test func cancellingKillsTheWholeGroupIncludingGrandchildren() async throws {
        let (temp, cli, caches) = try setup(mode: "child")
        defer { temp.remove() }
        let runner = makeRunner(cli, caches: caches)
        let task = Task { try await runner.run(makeRequest(timeout: .seconds(60)), authorization: allowed) }
        let appeared = await eventually { !cli.read("childpid").isEmpty }
        #expect(appeared)
        let childPID = pid_t(cli.read("childpid").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(childPID > 0)
        #expect(kill(childPID, 0) == 0)  // alive before
        let cancelledAt = Date()
        task.cancel()
        await #expect(throws: ProviderError.cancelled) { try await task.value }
        // The guard is generous so a loaded machine cannot fail it by accident; the duration is asserted apart from
        // it. SIGTERM goes out at once and SIGKILL 2 s later, so the group is gone well inside 10 s.
        let gone = await eventually(timeout: 30) { kill(childPID, 0) != 0 }
        #expect(gone, "the grandchild must die with the group")
        #expect(Date().timeIntervalSince(cancelledAt) < 10, "the group kill must not be delayed")
    }

    @Test func aGrandchildThatLeavesTheGroupCannotHoldTheRunOpen() async throws {
        // The grandchild calls setsid(), so the group kill cannot reach it, and it keeps the three pipes open while
        // the fake never reads stdin. The run must still end soon after the leader exits and release the gate.
        let (temp, cli, caches) = try setup(mode: "escape")
        defer {
            if let pid = pid_t(cli.read("escapedpid").trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
            temp.remove()
        }
        let gate = ProviderGate()
        let runner = makeRunner(cli, caches: caches, gate: gate)
        let request = ProviderRequest(
            feature: .meetingsNotes, model: "sonnet",
            messages: [ChatMessage(role: "user", content: String(repeating: "zebra ", count: 60_000))],
            timeout: .seconds(120))  // the grandchild sleeps 120 s: neither it nor this timeout can end the run early
        let done = DoneFlag()
        let began = Date()
        let task = Task {
            defer { done.set() }
            let result = try await runner.run(request, authorization: allowed)
            return (result, Date().timeIntervalSince(began))
        }
        // The guard only keeps a hang from stalling the suite; how long the run took is asserted separately below.
        let finished = await eventually(timeout: 30) { done.value }
        #expect(finished, "an escaped grandchild must not keep the run (and the gate slot) open")
        guard finished else {
            task.cancel()
            return
        }
        let (result, elapsed) = try await task.value
        #expect(result.text == "Fake answer.")
        #expect(elapsed < 10, "the run must end soon after the leader exits (drain grace 2 s), not at the timeout")
        #expect(await gate.queuedCount == 0)
    }

    @Test func aTaskCancelledBeforeTheStartStartsNothing() async throws {
        let (temp, cli, caches) = try setup()
        defer { temp.remove() }
        let runner = makeRunner(cli, caches: caches)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(makeRequest(), authorization: allowed)
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(cli.read("argv").isEmpty)
    }

    @Test(arguments: [
        ("login", ProviderFailure.notSignedIn), ("rate", .rateLimited), ("badflag", .incompatibleVersion),
        ("exit3", .other), ("empty", .other),
    ])
    func errorsAreSortedIntoTheClosedSet(mode: String, expected: ProviderFailure) async throws {
        let (temp, cli, caches) = try setup(mode: mode)
        defer { temp.remove() }
        await #expect(throws: ProviderError.failed(expected)) {
            try await makeRunner(cli, caches: caches).run(makeRequest(), authorization: allowed)
        }
    }

    @Test func aTruncatedAnswerIsFlaggedNotReturnedAsText() async throws {
        let (temp, cli, caches) = try setup(mode: "trunc")
        defer { temp.remove() }
        let result = try await makeRunner(cli, caches: caches).run(makeRequest(), authorization: allowed)
        #expect(result.stoppedByTokenLimit)
        #expect(result.text.isEmpty)
    }

    @Test func stderrNeverReachesTheErrorOrTheDescription() async throws {
        let (temp, cli, caches) = try setup(mode: "badflag")
        defer { temp.remove() }
        do {
            _ = try await makeRunner(cli, caches: caches).run(makeRequest(), authorization: allowed)
            Issue.record("expected a failure")
        } catch {
            let text = String(describing: error) + String(reflecting: error) + error.localizedDescription
            #expect(!text.contains(syntheticCanary))
            #expect(!text.contains("--zzz"))
        }
    }

    @Test func aMissingBinaryIsNotInstalledAndStartsNothing() async throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let runner = ProviderRunner(
            system: ProviderSystem(locator: FixedLocator(url: nil), process: LiveProviderProcess()),
            descriptors: [ProviderDescriptor.claudeCode.with(isolationVerified: true)],
            cachesDirectory: temp.url.appending(path: "c"), gate: ProviderGate())
        await #expect(throws: ProviderError.notInstalled) {
            try await runner.run(makeRequest(), authorization: allowed)
        }
        #expect(await runner.status(of: .claudeCode) == .notInstalled)
    }

    @Test func statusReadsVersionAndLogin() async throws {
        let (temp, cli, caches) = try setup()
        defer { temp.remove() }
        let runner = makeRunner(cli, caches: caches)
        #expect(await runner.status(of: .claudeCode) == .ready)
        cli.setMode("loggedout")
        #expect(await runner.status(of: .claudeCode) == .notSignedIn)
    }

    @Test func tryOutSendsOnlyAFixedText() async throws {
        let (temp, cli, caches) = try setup()
        defer { temp.remove() }
        let result = await makeRunner(cli, caches: caches).tryOut(provider: .claudeCode, model: "sonnet")
        #expect(result == .worked)
        #expect(cli.read("stdin") == "Reply with the single word OK.")
        #expect(ProviderDescriptor.claudeCode.isolationProblems(arguments: cli.lines("argv")).isEmpty)
    }

    @Test func staleWorkspacesAreSweptAtStart() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let stale = temp.url.appending(path: "provider-old")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let other = temp.url.appending(path: "keep")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        ProviderRunner(system: .quiet, cachesDirectory: temp.url).sweepStaleWorkspaces()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }
}
