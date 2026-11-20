import Foundation
import LintelSpeech

/// The one way to run a process with content. It asks the consumer's authorization directly before every start,
/// after the request has left the queue; a refusal, an unverified descriptor or an argv that breaks an isolation
/// requirement ends in an error and no process. Nothing in the app calls it yet.
public struct ProviderRunner: Sendable {
    private let system: ProviderSystem
    private let gate: ProviderGate
    private let descriptors: [ProviderDescriptor]
    private let cachesDirectory: URL
    private let manualBinaryPath: @Sendable () -> String?
    private let environment: @Sendable () -> [String: String]

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

    public func run(_ request: ProviderRequest, authorization: ProviderAuthorization) async throws -> GenerationResult {
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
            let spec = try makeSpec(descriptor: descriptor, arguments: argv, stdin: stdin, timeout: request.timeout)
            defer { spec.workspace.remove() }
            ProviderLog.record(.contentProcessStarted, provider: id)
            return try await system.process.runContent(spec.value)
        }
        try Self.check(output.ending, provider: id)
        ProviderLog.record(.processFinished, provider: id, millis: Self.millis(since: started))
        return try interpret(output, descriptor: descriptor)
    }

    // MARK: probes (no user content)

    public func status(of provider: ProviderID) async -> ProviderStatus {
        guard let descriptor = descriptors.first(where: { $0.id == provider }) else { return .notInstalled }
        do {
            let version = try await probe(descriptor, arguments: descriptor.versionArguments, stdin: Data())
            guard version.ending == .exited, version.exitCode == 0 else { return .incompatibleVersion }
            let auth = try await probe(descriptor, arguments: descriptor.authStatusArguments, stdin: Data())
            let authData = auth.exitCode == 0 ? auth.stdout : nil
            return descriptor.status(versionOutput: version.stdout, authOutput: authData)
        } catch ProviderError.notInstalled {
            return .notInstalled
        } catch {
            return .incompatibleVersion
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
                let spec = try makeSpec(
                    descriptor: descriptor, arguments: argv, stdin: Data("Reply with the single word OK.".utf8),
                    timeout: .seconds(120))
                defer { spec.workspace.remove() }
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

    private struct PreparedSpec {
        let value: ProviderProcessSpec
        let workspace: ProviderWorkspace
    }

    private func makeSpec(
        descriptor: ProviderDescriptor, arguments: [String], stdin: Data, timeout: Duration
    ) throws -> PreparedSpec {
        guard let binary = system.locator.locate(descriptor, manualPath: manualBinaryPath()) else {
            ProviderLog.record(.refusedNotInstalled, provider: descriptor.id)
            throw ProviderError.notInstalled
        }
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
            let spec = try makeSpec(descriptor: descriptor, arguments: arguments, stdin: stdin, timeout: .seconds(30))
            defer { spec.workspace.remove() }
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
