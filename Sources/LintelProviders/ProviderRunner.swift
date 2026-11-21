import Foundation
import LintelSpeech

/// The one way to run a process with content. It asks the consumer's authorization directly before every start,
/// after the request has left the queue; a refusal, an unverified descriptor or an argv that breaks an isolation
/// requirement ends in an error and no process. The one consumer is `MeetingsPlugin`'s `ProviderNotesGenerator`, whose
/// authorization is "the provider is chosen in settings right now".
public struct ProviderRunner: Sendable {
    private let system: ProviderSystem
    private let gate: ProviderGate
    private let descriptors: [ProviderDescriptor]
    private let cachesDirectory: URL
    private let manualBinaryPath: @Sendable () -> String?
    private let environment: @Sendable () -> [String: String]
    /// Which hand-picked binaries already answered the identity probe (see `prepareBinary`).
    private let proven = ManualBinaryProof()

    public init(
        system: ProviderSystem,
        cachesDirectory: URL,
        gate: ProviderGate = .shared,
        manualBinaryPath: @escaping @Sendable () -> String? = { nil },
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.init(
            system: system, descriptors: [.claudeCode], cachesDirectory: cachesDirectory, gate: gate,
            manualBinaryPath: manualBinaryPath, environment: environment)
    }

    init(
        system: ProviderSystem,
        descriptors: [ProviderDescriptor],
        cachesDirectory: URL,
        gate: ProviderGate = .shared,
        manualBinaryPath: @escaping @Sendable () -> String? = { nil },
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.system = system
        self.descriptors = descriptors
        self.cachesDirectory = cachesDirectory
        self.gate = gate
        self.manualBinaryPath = manualBinaryPath
        self.environment = environment
    }

    /// Removes `provider-*` directories a crash left behind. Call once at start, before any run.
    public func sweepStaleWorkspaces() {
        ProviderWorkspace.sweep(in: cachesDirectory)
    }

    // MARK: content

    /// `onExactModel` gets the model the CLI reports it used (the alias is not the exact version), when it reports one.
    public func run(
        _ request: ProviderRequest, authorization: ProviderAuthorization,
        onExactModel: (@Sendable (String) -> Void)? = nil
    ) async throws -> GenerationResult {
        let descriptor = try self.descriptor(for: request.provider)
        let (argv, stdin) = try prepare(request, descriptor: descriptor)
        let id = descriptor.id
        let system = self.system
        let started = ContinuousClock.now
        let output: ProviderProcessOutput = try await gate.withSlot(id) {
            // After the queue, directly before the start: the consumer's answer at this moment.
            if case .denied(let reason) = await authorization() {
                ProviderLog.record(.refusedNotAuthorized, provider: id)
                throw ProviderError.notAuthorized(reason)
            }
            try Task.checkCancellation()
            let binary = try await prepareBinary(descriptor)
            let spec = try makeSpec(
                binary: binary.url, descriptor: descriptor, arguments: argv, stdin: stdin, timeout: request.timeout)
            defer { spec.workspace.remove() }
            // Directly before the start: the file is still the one that answered the probe.
            try binary.recheck()
            ProviderLog.record(.contentProcessStarted, provider: id)
            return try await system.process.runContent(spec.value)
        }
        try Self.check(output.ending, provider: id)
        ProviderLog.record(.processFinished, provider: id, millis: Self.millis(since: started))
        if let exact = descriptor.exactModel(stdout: output.stdout) { onExactModel?(exact) }
        return try interpret(output, descriptor: descriptor)
    }

    // MARK: probes (no user content)

    public func status(of provider: ProviderID) async -> ProviderStatus {
        await report(of: provider).status
    }

    /// The status and the CLI's version number (`2.1.329`), for the Settings row. The two probes carry no content.
    public func report(of provider: ProviderID) async -> ProviderStatusReport {
        guard let descriptor = descriptors.first(where: { $0.id == provider }) else {
            return ProviderStatusReport(status: .notInstalled, version: nil)
        }
        do {
            let version = try await probe(descriptor, arguments: descriptor.versionArguments, stdin: Data())
            guard version.ending == .exited, version.exitCode == 0 else {
                return ProviderStatusReport(status: .incompatibleVersion, version: nil)
            }
            let number = ProviderVersion(parsing: String(decoding: version.stdout, as: UTF8.self))
                .map { $0.parts.map(String.init).joined(separator: ".") }
            let auth = try await probe(descriptor, arguments: descriptor.authStatusArguments, stdin: Data())
            let authData = auth.exitCode == 0 ? auth.stdout : nil
            return ProviderStatusReport(
                status: descriptor.status(versionOutput: version.stdout, authOutput: authData), version: number)
        } catch ProviderError.notInstalled {
            return ProviderStatusReport(status: .notInstalled, version: nil)
        } catch {
            return ProviderStatusReport(status: .incompatibleVersion, version: nil)
        }
    }

    /// A fixed text of ours, nothing of the user's. Needs the isolation proof like a content run, but no consent.
    public func tryOut(provider: ProviderID, model: String) async -> TryOutResult {
        guard let descriptor = descriptors.first(where: { $0.id == provider }), descriptor.isolationVerified else {
            ProviderLog.record(.refusedIsolationNotVerified, provider: provider)
            return .unavailable
        }
        do {
            let argv = try descriptor.arguments(model: model, systemPrompt: "")
            guard descriptor.isolationProblems(arguments: argv).isEmpty else {
                ProviderLog.record(.refusedIsolationProblem, provider: provider)
                return .unavailable
            }
            let system = self.system
            let output: ProviderProcessOutput = try await gate.withSlot(provider) {
                let binary = try await prepareBinary(descriptor)
                let spec = try makeSpec(
                    binary: binary.url, descriptor: descriptor, arguments: argv,
                    stdin: Data("Reply with the single word OK.".utf8), timeout: .seconds(120))
                defer { spec.workspace.remove() }
                try binary.recheck()
                ProviderLog.record(.probeProcessStarted, provider: provider)
                return try await system.process.runProbe(spec.value)
            }
            guard output.ending == .exited else { return .failed(.other) }
            switch try interpret(output, descriptor: descriptor) {
            case let result where !result.text.isEmpty && !result.stoppedByTokenLimit: return .worked
            default: return .failed(.other)
            }
        } catch ProviderError.failed(let failure) {
            return .failed(failure)
        } catch ProviderError.notInstalled {
            return .unavailable
        } catch {
            return .failed(.other)
        }
    }

    // MARK: internals

    private func descriptor(for id: ProviderID) throws -> ProviderDescriptor {
        guard let descriptor = descriptors.first(where: { $0.id == id }) else {
            throw ProviderError.unsupportedProvider
        }
        guard descriptor.isolationVerified else {
            ProviderLog.record(.refusedIsolationNotVerified, provider: id)
            throw ProviderError.isolationNotVerified
        }
        return descriptor
    }

    /// Argv and stdin, with the isolation check on the argv. Throws before anything is queued.
    private func prepare(_ request: ProviderRequest, descriptor: ProviderDescriptor) throws -> ([String], Data) {
        let systemPrompt = request.messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let content = request.messages.filter { $0.role != "system" }.map(\.content).joined(separator: "\n\n")
        guard !content.isEmpty else { throw ProviderError.invalidRequest }
        let argv = try descriptor.arguments(model: request.model, systemPrompt: systemPrompt)
        let problems = descriptor.isolationProblems(arguments: argv)
        guard problems.isEmpty else {
            ProviderLog.record(.refusedIsolationProblem, provider: descriptor.id)
            throw ProviderError.isolationProblem(problems)
        }
        return (argv, Data(content.utf8))
    }

    /// The binary for ONE process: the path setting is read once here, links are resolved once, and the result (a
    /// URL and, for a hand-picked file, its identity) is what the probe and the process that follows both use; no
    /// later step reads the setting or the path again. A binary the user picked by hand (or a `defaults write`) is
    /// trusted only after it answered the version probe as this provider's CLI: its file name is one of the
    /// descriptor's names and `--version` names the product and a version. The answer is tied to the file's
    /// identity (device, inode, size, change time), so a replaced file is asked again, and `recheck()` compares it
    /// once more directly before a process with content starts. The probe carries no content: argv is `--version`,
    /// stdin is empty. Runs inside the provider's queue slot; the search of the fixed directories needs no proof
    /// (it finds only the installer's places).
    private func prepareBinary(_ descriptor: ProviderDescriptor) async throws -> ResolvedBinary {
        let manual = manualBinaryPath().flatMap { $0.isEmpty ? nil : $0 }
        guard let manual else {
            guard let url = system.locator.locate(descriptor, manualPath: nil) else {
                ProviderLog.record(.refusedNotInstalled, provider: descriptor.id)
                throw ProviderError.notInstalled
            }
            return ResolvedBinary(url: url, identity: nil)
        }
        guard descriptor.binaryNames.contains(URL(filePath: manual).lastPathComponent),
            let url = system.locator.locate(descriptor, manualPath: manual),
            let identity = ManualBinaryProof.identityKey(of: url)
        else {
            ProviderLog.record(.refusedNotInstalled, provider: descriptor.id)
            throw ProviderError.notInstalled
        }
        let binary = ResolvedBinary(url: url, identity: identity)
        if proven.contains(identity) { return binary }
        let spec = try makeSpec(
            binary: url, descriptor: descriptor, arguments: descriptor.versionArguments, stdin: Data(),
            timeout: .seconds(30))
        defer { spec.workspace.remove() }
        try binary.recheck()
        ProviderLog.record(.probeProcessStarted, provider: descriptor.id)
        let output = try await system.process.runProbe(spec.value)
        let text = String(decoding: output.stdout, as: UTF8.self)
        guard output.ending == .exited, output.exitCode == 0, text.contains(descriptor.displayName),
            ProviderVersion(parsing: text) != nil
        else {
            ProviderLog.record(.refusedNotInstalled, provider: descriptor.id)
            throw ProviderError.notInstalled
        }
        // The file that answered must be the one that was named: if it changed while the probe ran, it is not proven.
        try binary.recheck()
        proven.insert(identity)
        return binary
    }

    struct ResolvedBinary {
        let url: URL
        /// `nil` for a binary found in the fixed directories.
        let identity: String?

        /// A hand-picked file that is no longer the one that was probed ends the run (no process starts).
        func recheck() throws {
            guard let identity else { return }
            guard ManualBinaryProof.identityKey(of: url) == identity else { throw ProviderError.notInstalled }
        }
    }

    private struct PreparedSpec {
        let value: ProviderProcessSpec
        let workspace: ProviderWorkspace
    }

    private func makeSpec(
        binary: URL, descriptor: ProviderDescriptor, arguments: [String], stdin: Data, timeout: Duration
    ) throws -> PreparedSpec {
        let workspace = try ProviderWorkspace.make(in: cachesDirectory)
        let value = ProviderProcessSpec(
            executable: binary, arguments: arguments,
            environment: ProviderEnvironment.make(from: environment(), allowlist: descriptor.environmentAllowlist),
            workingDirectory: workspace.url, stdin: stdin, timeout: timeout)
        return PreparedSpec(value: value, workspace: workspace)
    }

    private func probe(_ descriptor: ProviderDescriptor, arguments: [String], stdin: Data) async throws
        -> ProviderProcessOutput
    {
        let system = self.system
        return try await gate.withSlot(descriptor.id) {
            let binary = try await prepareBinary(descriptor)
            let spec = try makeSpec(
                binary: binary.url, descriptor: descriptor, arguments: arguments, stdin: stdin, timeout: .seconds(30))
            defer { spec.workspace.remove() }
            try binary.recheck()
            ProviderLog.record(.probeProcessStarted, provider: descriptor.id)
            return try await system.process.runProbe(spec.value)
        }
    }

    private static func check(_ ending: ProviderProcessOutput.Ending, provider: ProviderID) throws {
        switch ending {
        case .exited: return
        case .timedOut:
            ProviderLog.record(.processTimedOut, provider: provider)
            throw ProviderError.timedOut
        case .cancelled:
            ProviderLog.record(.processCancelled, provider: provider)
            throw ProviderError.cancelled
        case .outputTooLarge:
            ProviderLog.record(.outputTooLarge, provider: provider)
            throw ProviderError.outputTooLarge
        }
    }

    private func interpret(_ output: ProviderProcessOutput, descriptor: ProviderDescriptor) throws -> GenerationResult {
        try Self.check(output.ending, provider: descriptor.id)
        let parsed = descriptor.parseOutput(output.stdout)
        if case .truncated = parsed { return GenerationResult(text: "", stoppedByTokenLimit: true) }
        if output.exitCode != 0 {
            throw ProviderError.failed(
                descriptor.classify(stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode))
        }
        switch parsed {
        case .answer(let text): return GenerationResult(text: text, stoppedByTokenLimit: false)
        case .truncated: return GenerationResult(text: "", stoppedByTokenLimit: true)
        case .failure(let failure): throw ProviderError.failed(failure)
        }
    }

    private static func millis(since start: ContinuousClock.Instant) -> Int {
        let parts = (ContinuousClock.now - start).components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}

/// What the identity probe established for hand-picked binaries (see `ProviderRunner.prepareBinary`).
final class ManualBinaryProof: @unchecked Sendable {
    private let lock = NSLock()
    private var proven: Set<String> = []

    func contains(_ identityKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return proven.contains(identityKey)
    }

    func insert(_ identityKey: String) {
        lock.lock()
        defer { lock.unlock() }
        proven.insert(identityKey)
    }

    /// The resolved path with the file's device, inode, size and change time: another file, or the same one changed,
    /// differs.
    static func identityKey(of url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return
            "\(url.path)|\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }
}
