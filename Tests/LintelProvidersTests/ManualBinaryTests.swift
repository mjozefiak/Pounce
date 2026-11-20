import Foundation
import Testing

@testable import LintelProviders

/// Owner decision 2026-11-20 (PR 215, "Choose File…" = variant A): a hand-picked binary is trusted only after a
/// version probe named it as this provider's CLI; without that, nothing with content starts, whoever wrote the path.
@Suite struct ManualBinaryTests {
    /// Answers the probe from a closure; counts both kinds of start. Content gets a valid answer.
    final class Process: ProviderProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var counts = (content: 0, probes: 0)
        private var versionOutput: String
        init(version: String) { versionOutput = version }
        var content: Int { lock.withLock { counts.content } }
        var probes: Int { lock.withLock { counts.probes } }
        func runContent(_ spec: ProviderProcessSpec) async throws -> ProviderProcessOutput {
            lock.withLock { counts.content += 1 }
            let data = Data(#"{"type":"result","is_error":false,"result":"ok"}"#.utf8)
            return ProviderProcessOutput(stdout: data, stderr: Data(), exitCode: 0, ending: .exited)
        }
        func runProbe(_ spec: ProviderProcessSpec) async throws -> ProviderProcessOutput {
            lock.withLock { counts.probes += 1 }
            return ProviderProcessOutput(
                stdout: Data(versionOutput.utf8), stderr: Data(), exitCode: 0, ending: .exited)
        }
    }

    private func make(
        path: String?, version: String = "2.1.328 (Claude Code)", file: URL? = nil
    ) throws -> (ProviderRunner, Process, TempDir) {
        let dir = try TempDir()
        let process = Process(version: version)
        let located = file ?? dir.url.appending(path: "claude")
        if file == nil {
            try Data("#!/bin/sh\n".utf8).write(to: located)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: located.path)
        }
        let runner = ProviderRunner(
            system: ProviderSystem(locator: FixedLocator(url: located), process: process),
            descriptors: [ProviderDescriptor.claudeCode.with(isolationVerified: true)],
            cachesDirectory: dir.url.appending(path: "caches"), gate: ProviderGate(),
            manualBinaryPath: { path })
        return (runner, process, dir)
    }

    @Test func aPathWithAnotherFileNameStartsNothingWithContent() async throws {
        let (runner, process, dir) = try make(path: "/usr/bin/cat")
        defer { dir.remove() }
        await #expect(throws: ProviderError.notInstalled) {
            try await runner.run(makeRequest(), authorization: allowed)
        }
        #expect(process.content == 0)
        #expect(process.probes == 0, "a foreign name is refused before any process")
    }

    @Test func aFileNamedLikeTheCLIThatDoesNotAnswerAsItStartsNothingWithContent() async throws {
        let (runner, process, dir) = try make(path: "/placeholder/claude", version: "hello from something else")
        defer { dir.remove() }
        await #expect(throws: ProviderError.notInstalled) {
            try await runner.run(makeRequest(), authorization: allowed)
        }
        #expect(process.content == 0)
        #expect(process.probes == 1)
        await #expect(throws: ProviderError.notInstalled) {
            try await runner.run(makeRequest(), authorization: allowed)
        }
        #expect(process.probes == 2, "a failed answer is not remembered")
        #expect(process.content == 0)
    }

    @Test func theCLIAnswersOnceAndThenSendsAndAChangedFileIsAskedAgain() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let file = dir.url.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let (runner, process, d2) = try make(path: file.path, file: file)
        defer { d2.remove() }
        _ = try await runner.run(makeRequest(), authorization: allowed)
        _ = try await runner.run(makeRequest(), authorization: allowed)
        #expect(process.probes == 1)
        #expect(process.content == 2)
        // The file is replaced (new size and change time): the proof is void.
        try Data("#!/bin/sh\n# changed\n".utf8).write(to: file)
        _ = try await runner.run(makeRequest(), authorization: allowed)
        #expect(process.probes == 2)
        #expect(process.content == 3)
    }

    @Test func noManualPathNeedsNoProbe() async throws {
        let (runner, process, dir) = try make(path: nil)
        defer { dir.remove() }
        _ = try await runner.run(makeRequest(), authorization: allowed)
        #expect(process.probes == 0)
        #expect(process.content == 1)
    }

    @Test func theProbeCarriesNoContent() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let file = dir.url.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        final class Spy: ProviderProcessRunning, @unchecked Sendable {
            let lock = NSLock()
            var probeSpecs: [ProviderProcessSpec] = []
            func runContent(_ spec: ProviderProcessSpec) async throws -> ProviderProcessOutput {
                ProviderProcessOutput(
                    stdout: Data(#"{"type":"result","is_error":false,"result":"ok"}"#.utf8), stderr: Data(),
                    exitCode: 0, ending: .exited)
            }
            func runProbe(_ spec: ProviderProcessSpec) async throws -> ProviderProcessOutput {
                lock.withLock { probeSpecs.append(spec) }
                return ProviderProcessOutput(
                    stdout: Data("2.1.328 (Claude Code)".utf8), stderr: Data(), exitCode: 0, ending: .exited)
            }
        }
        let spy = Spy()
        let runner = ProviderRunner(
            system: ProviderSystem(locator: FixedLocator(url: file), process: spy),
            descriptors: [ProviderDescriptor.claudeCode.with(isolationVerified: true)],
            cachesDirectory: dir.url.appending(path: "caches"), gate: ProviderGate(), manualBinaryPath: { file.path })
        _ = try await runner.run(makeRequest(), authorization: allowed)
        let spec = try #require(spy.probeSpecs.first)
        #expect(spec.arguments == ["--version"])
        #expect(spec.stdin.isEmpty)
    }

    @Test func theStatusRowAlsoRefusesAForeignFile() async throws {
        let (runner, process, d2) = try make(path: "/placeholder/claude", version: "hello")
        defer { d2.remove() }
        let report = await runner.report(of: .claudeCode)
        #expect(report.status == .notInstalled)
        #expect(process.content == 0)
    }
}
