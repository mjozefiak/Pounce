import Darwin
import Foundation

/// What to run. Content goes in `stdin`, never in `arguments`.
struct ProviderProcessSpec: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
    let stdin: Data
    let timeout: Duration
    var maxStdoutBytes: Int = 1_048_576
    var maxStderrBytes: Int = 65_536
}

struct ProviderProcessOutput: Sendable {
    enum Ending: Sendable, Equatable { case exited, timedOut, cancelled, outputTooLarge }
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
    let ending: Ending
}

/// The two entries to a child process. `runContent` carries user content and is called only from
/// `ProviderRunner.run` (a source test checks it); `runProbe` carries a constant (`--version`, `auth status`, "Try
/// it") and no user data.
protocol ProviderProcessRunning: Sendable {
    func runContent(_ spec: ProviderProcessSpec) async throws -> ProviderProcessOutput
    func runProbe(_ spec: ProviderProcessSpec) async throws -> ProviderProcessOutput
}

/// The real process runner. The only place in this target that starts a process (`posix_spawn`).
struct LiveProviderProcess: ProviderProcessRunning {
    private static let counter = LockedCounter()
    /// How many real processes this app instance started. A test of the quiet system checks it did not move.
    static var startedCount: Int { counter.value }

    func runContent(_ spec: ProviderProcessSpec) async throws -> ProviderProcessOutput {
        try await execute(spec)
    }

    func runProbe(_ spec: ProviderProcessSpec) async throws -> ProviderProcessOutput {
        try await execute(spec)
    }

    private func execute(_ spec: ProviderProcessSpec) async throws -> ProviderProcessOutput {
        try Task.checkCancellation()
        let job = try ProcessJob(spec)
        Self.counter.increment()
        return await withTaskCancellationHandler {
            await job.finished()
        } onCancel: {
            job.cancel()
        }
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// One child in its own process group. SIGTERM goes to the whole group, SIGKILL 2 s later, and the group is killed
/// when the leader has exited, so no grandchild outlives the call.
private final class ProcessJob: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var reaped = false
    private var ending: ProviderProcessOutput.Ending = .exited
    private var stdoutData = Data()
    private var stderrData = Data()
    private var exitCode: Int32 = 0
    private let group = DispatchGroup()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "providers.process", attributes: .concurrent)

    init(_ spec: ProviderProcessSpec) throws {
        var inPipe: [Int32] = [0, 0]
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0 else { throw ProviderError.launchFailed }
        guard pipe(&outPipe) == 0 else {
            Self.closeAll(inPipe)
            throw ProviderError.launchFailed
        }
        guard pipe(&errPipe) == 0 else {
            Self.closeAll(inPipe)
            Self.closeAll(outPipe)
            throw ProviderError.launchFailed
        }
        for fd in inPipe + outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        let chdirStatus = spec.workingDirectory.path.withCString { posix_spawn_file_actions_addchdir(&actions, $0) }
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setpgroup(&attributes, 0)
        // CLOEXEC_DEFAULT: the child inherits nothing of the app except the three descriptors set above.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv = ([spec.executable.path] + spec.arguments).map { strdup($0) } + [nil]
        let envp = spec.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var child: pid_t = 0
        let status =
            chdirStatus == 0 ? posix_spawn(&child, spec.executable.path, &actions, &attributes, argv, envp) : -1
        close(inPipe[0])
        close(outPipe[1])
        close(errPipe[1])
        guard status == 0 else {
            close(inPipe[1])
            close(outPipe[0])
            close(errPipe[0])
            throw ProviderError.launchFailed
        }
        pid = child
        let leader = child

        let stdinFD = inPipe[1]
        let outFD = outPipe[0]
        let errFD = errPipe[0]
        group.enter()
        queue.async { [stdin = spec.stdin] in
            Self.writeAll(stdin, to: stdinFD)
            close(stdinFD)
            self.group.leave()
        }
        group.enter()
        queue.async { [limit = spec.maxStdoutBytes] in
            let (data, overflow) = Self.readAll(outFD, limit: limit) { self.finish(.outputTooLarge) }
            close(outFD)
            self.lock.withLock { self.stdoutData = data }
            _ = overflow
            self.group.leave()
        }
        group.enter()
        queue.async { [limit = spec.maxStderrBytes] in
            let (data, _) = Self.readAll(errFD, limit: limit) {}
            close(errFD)
            self.lock.withLock { self.stderrData = data }
            self.group.leave()
        }
        group.enter()
        queue.async {
            var raw: Int32 = 0
            while waitpid(leader, &raw, 0) == -1 && errno == EINTR {}
            let code: Int32 = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
            self.lock.withLock {
                self.reaped = true
                self.exitCode = code
            }
            killpg(leader, SIGKILL)  // anything the child left behind in its group
            self.group.leave()
        }
        let seconds = Double(spec.timeout.components.seconds) + Double(spec.timeout.components.attoseconds) / 1e18
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(seconds, 0.001))
        timer.setEventHandler { [weak self] in self?.finish(.timedOut) }
        self.timer = timer
        timer.resume()
    }

    func cancel() { finish(.cancelled) }

    func finished() async -> ProviderProcessOutput {
        await withCheckedContinuation { continuation in
            group.notify(queue: queue) {
                self.timer?.cancel()
                let output = self.lock.withLock {
                    ProviderProcessOutput(
                        stdout: self.stdoutData, stderr: self.stderrData, exitCode: self.exitCode,
                        ending: self.ending)
                }
                continuation.resume(returning: output)
            }
        }
    }

    /// The first reason wins. Terminates the whole group: SIGTERM now, SIGKILL after 2 s.
    private func finish(_ reason: ProviderProcessOutput.Ending) {
        let shouldKill: Bool = lock.withLock {
            guard ending == .exited, !reaped else { return false }
            ending = reason
            return true
        }
        guard shouldKill else { return }
        killpg(pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            let alive = lock.withLock { !reaped }
            if alive { killpg(pid, SIGKILL) }
        }
    }

    private static func closeAll(_ pair: [Int32]) {
        for fd in pair { _ = Darwin.close(fd) }
    }

    private static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, min(65_536, buffer.count - offset))
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    /// Reads to end of file, keeps at most `limit` bytes, keeps draining after that so the child never blocks.
    private static func readAll(_ fd: Int32, limit: Int, onOverflow: () -> Void) -> (Data, Bool) {
        var data = Data()
        var overflow = false
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break }
            if data.count + count > limit {
                if !overflow {
                    overflow = true
                    onOverflow()
                }
                data.append(contentsOf: buffer[0..<max(0, limit - data.count)])
            } else {
                data.append(contentsOf: buffer[0..<count])
            }
        }
        return (data, overflow)
    }
}
