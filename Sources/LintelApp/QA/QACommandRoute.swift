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
/// `resetState`, `restoreAll`, `snap <zone>`, `import <path>`, `export <path>`, `addFloating <bundle id>`).
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
    private var pending = ""
    private var task: Task<Void, Never>?

    init(
        file: URL, commands: @escaping @MainActor () -> [PluginCommand],
        qaPlugin: @escaping @MainActor (String) -> (any PluginQACommands)?
    ) {
        self.file = file
        log = file.appendingPathExtension("log")
        self.commands = commands
        self.qaPlugin = qaPlugin
    }

    /// Starts polling. The file is created empty when it does not exist.
    func start(clock: any Clock<Duration> = ContinuousClock()) {
        guard task == nil else { return }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
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
        guard let data = try? Data(contentsOf: file), data.count > offset else { return }
        pending += String(decoding: data[offset...], as: UTF8.self)
        offset = data.count
        while let end = pending.firstIndex(of: "\n") {
            let line = String(pending[..<end]).trimmingCharacters(in: .whitespaces)
            pending = String(pending[pending.index(after: end)...])
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

    private func append(_ text: String) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
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
