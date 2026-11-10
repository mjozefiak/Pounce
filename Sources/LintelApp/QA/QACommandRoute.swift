#if DEBUG
import Foundation
import LintelKit

/// DEBUG-only QA command route (`--qa-command-file <path>`, `docs/qa.md`): reads one command per line from a file that
/// the tester appends to, runs it through the same entry points the shortcuts and menus use, and appends the result
/// to `<path>.log`. It exists only in a debug `--qa` run (`AppEnvironment.qa`), polls at a bounded interval, and is
/// compiled out of release builds.
///
/// A line is `<command id>` (any active plugin command, for example `windows.workspace.2`, `windows.focus.left`,
/// `windows.toggleLayout`, `windows.zones.nextLayout`, `windows.zones.layout.3`, `windows.restoreAllWindows`) or
/// `qa <plugin id> <verb ...>` for a verb of a plugin that implements `PluginQACommands` (Window Management:
/// `resetState`, `restoreAll`, `snap <zone>`, `import <path>`, `export <selected|all> <path>`, `addFloating <bundle id>`).
/// Lines starting with `#` and empty lines are ignored.
@MainActor
final class QACommandRoute {
    /// How often the file is looked at.
    static let pollInterval: Duration = .milliseconds(50)

    private let file: URL
    private let log: URL
    private let commands: @MainActor () -> [PluginCommand]
    private let qaPlugin: @MainActor (String) -> (any PluginQACommands)?
    private var offset = 0
    /// Bytes read but not yet a whole line: a multi-byte character may be split across two polls, so only complete
    /// lines are decoded.
    private var pending = Data()
    /// The last bytes already read, and the file they came from: a file replaced by one of the same or a larger
    /// size (a truncate and rewrite) is noticed by them.
    private var tail = Data()
    private var fileNumber: Int?
    private static let tailLength = 16
    private var task: Task<Void, Never>?

    /// Whether the commands already in the file at launch are run (`--qa-command-replay`). By default the route starts
    /// at the end of the file, so a relaunch does not replay the whole earlier run.
    private let replay: Bool

    init(
        file: URL, replay: Bool = false, commands: @escaping @MainActor () -> [PluginCommand],
        qaPlugin: @escaping @MainActor (String) -> (any PluginQACommands)?
    ) {
        self.replay = replay
        self.file = file
        log = file.appendingPathExtension("log")
        self.commands = commands
        self.qaPlugin = qaPlugin
    }

    /// Creates the file when it does not exist and, unless the run replays, starts at its end.
    func prepare() {
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        } else if !replay {
            offset = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0
        }
    }

    /// Starts polling.
    func start(clock: any Clock<Duration> = ContinuousClock()) {
        guard task == nil else { return }
        prepare()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                do { try await clock.sleep(for: Self.pollInterval) } catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Reads what was appended since the last look and runs every complete line, in order.
    func pollOnce() async {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        let number = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.systemFileNumber] as? Int
        var replaced = size < offset || (fileNumber != nil && number != fileNumber)
        if !replaced, offset > 0, !tail.isEmpty {
            try? handle.seek(toOffset: UInt64(offset - tail.count))
            replaced = (try? handle.read(upToCount: tail.count)) != tail
        }
        // A file that was emptied or replaced starts again from its beginning.
        if replaced {
            offset = 0
            pending = Data()
            tail = Data()
        }
        fileNumber = number
        guard size > offset else { return }
        // Only what was appended since the last look is read.
        try? handle.seek(toOffset: UInt64(offset))
        guard let data = try? handle.readToEnd() else { return }
        pending.append(data)
        offset += data.count
        tail = Data((tail + data).suffix(Self.tailLength))
        while let end = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            pending = Data(pending[pending.index(after: end)...])
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            append("\(await run(line)) | \(line)")
        }
    }

    /// Runs one line and answers `ok` or `error: ...`.
    func run(_ line: String) async -> String {
        let words = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        if words.first == "qa" {
            guard words.count >= 3, let plugin = qaPlugin(words[1]) else { return "error: no such plugin or verb" }
            return await plugin.runQACommand(words[2])
        }
        guard let command = commands().first(where: { $0.id == line }) else { return "error: unknown command" }
        await command.run()
        return "ok"
    }

    /// The log keeps at most this much; past it the whole log moves to `<path>.log.1` (one previous log is kept, an older one is dropped).
    static let logLimit = 256 * 1024

    private func append(_ text: String) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: log.path))?[.size] as? Int) ?? 0
        if size > Self.logLimit {
            let rotated = log.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: log, to: rotated)
        }
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: log)
        }
    }
}
#endif
