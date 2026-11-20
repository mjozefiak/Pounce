import Foundation

/// Every part of this target that reaches the system (finding the binary, starting a process; in phase 2 the
/// network). `live` is the app's; `quiet` is installed in tests: a fake locator and a fake process that counts starts.
public struct ProviderSystem: Sendable {
    let locator: any ProviderLocating
    let process: any ProviderProcessRunning
    let quietProcess: QuietProviderProcess?

    init(locator: any ProviderLocating, process: any ProviderProcessRunning, quietProcess: QuietProviderProcess? = nil)
    {
        self.locator = locator
        self.process = process
        self.quietProcess = quietProcess
    }

    public static func live(homeDirectory: URL) -> ProviderSystem {
        ProviderSystem(locator: ProviderLocator(homeDirectory: homeDirectory), process: LiveProviderProcess())
    }

    /// A fake binary location and a fake process: nothing real starts. Counters are on `quietProcess`.
    public static func quiet(_ process: QuietProviderProcess = QuietProviderProcess()) -> ProviderSystem {
        ProviderSystem(locator: QuietProviderLocator(), process: process, quietProcess: process)
    }

    public static var quiet: ProviderSystem { quiet() }

    /// Counters of the quiet process (nil for a live system).
    public var quietRuns: QuietProviderProcess? { quietProcess }

    /// Real processes started so far in this app instance, by any system. Tests of `quiet` check it did not move.
    public static var realProcessesStarted: Int { LiveProviderProcess.startedCount }
}

struct QuietProviderLocator: ProviderLocating {
    func locate(_ descriptor: ProviderDescriptor, manualPath: String?) -> URL? {
        URL(filePath: "/nonexistent/lintel-quiet-provider")
    }
}

/// A process that is never started. It counts calls and answers with a scripted JSON result.
public final class QuietProviderProcess: ProviderProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var content = 0
    private var probes = 0
    private var response: Data

    public init(response: String = #"{"type":"result","is_error":false,"result":"ok"}"#) {
        self.response = Data(response.utf8)
    }

    /// Processes with content that would have started.
    public var contentRuns: Int { lock.withLock { content } }
    public var probeRuns: Int { lock.withLock { probes } }

    public func setResponse(_ text: String) { lock.withLock { response = Data(text.utf8) } }

    func runContent(_ spec: ProviderProcessSpec) async throws -> ProviderProcessOutput {
        let data = lock.withLock { () -> Data in
            content += 1
            return response
        }
        return ProviderProcessOutput(stdout: data, stderr: Data(), exitCode: 0, ending: .exited)
    }

    func runProbe(_ spec: ProviderProcessSpec) async throws -> ProviderProcessOutput {
        let data = lock.withLock { () -> Data in
            probes += 1
            return response
        }
        return ProviderProcessOutput(stdout: data, stderr: Data(), exitCode: 0, ending: .exited)
    }
}
