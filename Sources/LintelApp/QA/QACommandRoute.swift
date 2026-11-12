#if DEBUG
import Foundation
import LintelKit

/// DEBUG-only QA command route (`--qa-command-file <path>`, `docs/qa.md`): reads one command per line from a file that
/// the tester appends to, runs it through the same entry points the shortcuts and menus use, and appends the result
/// to `<path>.log`. It exists only in a debug `--qa` run (`AppEnvironment.qa`), polls at a bounded interval, and is
/// compiled out of release builds.
///
/// A line is `<command id>` or `qa <plugin id> <verb ...>`.
///
/// - `<command id>` is any active plugin command (for example `windows.workspace.2`, `windows.moveToWorkspace.3`,
///   `windows.focus.left`, `windows.toggleLayout`, `windows.restoreAllWindows`). It runs through `PluginCommand.run`,
///   the closure the keyboard shortcut calls, so the plugin's own dispatcher, its focus read and its Accessibility gate
///   are exercised on isolated data. What a `--qa` run does **not** cover is the shortcut layer: Carbon registration and
///   the translation of keys on the active layout (`docs/qa.md`).
/// - `qa <plugin id> <verb ...>` is a verb of a plugin that implements `PluginQACommands` (Window Management: `state`,
///   `resetState`, `restoreAll`, `snap <zone>`, `import <path>`, `export <selected|all> <path>`,
///   `addFloating <bundle id>`).
///
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
    /// What identifies the part of the file already read: the first and the last bytes of it and the file's number
    /// (inode). A file replaced, or truncated and rewritten, shows a different one even when it ends up as long as
    /// before (only an in-place rewrite to the same bytes cannot be told apart, and it would run the same commands).
    private var head = Data()
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

    /// Creates the file when it does not exist and, unless the run replays, starts at its end, remembering what the
    /// part before it looked like (so a rewrite before the first poll is noticed too).
    func prepare() {
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        } else if !replay {
            offset = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0
            if let handle = try? FileHandle(forReadingFrom: file) {
                defer { try? handle.close() }
                remember(handle)
            }
        }
    }

    /// Records the first and the last bytes before `offset` and the file's number.
    private func remember(_ handle: FileHandle) {
        let count = min(Self.tailLength, offset)
        try? handle.seek(toOffset: 0)
        head = (try? handle.read(upToCount: count)) ?? Data()
        try? handle.seek(toOffset: UInt64(offset - count))
        tail = (try? handle.read(upToCount: count)) ?? Data()
        fileNumber = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.systemFileNumber] as? Int
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
            try? handle.seek(toOffset: 0)
            let first = try? handle.read(upToCount: head.count)
            try? handle.seek(toOffset: UInt64(offset - tail.count))
            let last = try? handle.read(upToCount: tail.count)
            replaced = first != head || last != tail
        }
        // A file that was emptied or replaced starts again from its beginning.
        if replaced {
            offset = 0
            pending = Data()
            head = Data()
            tail = Data()
        }
        fileNumber = number
        guard size > offset else { return }
        // Only what was appended since the last look is read.
        try? handle.seek(toOffset: UInt64(offset))
        guard let data = try? handle.readToEnd() else { return }
        pending.append(data)
        offset += data.count
        remember(handle)
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
