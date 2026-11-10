#if DEBUG
import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// The DEBUG-only QA command route: a file the tester appends to, run in order through the commands the shortcuts
/// use, results in `<file>.log`. Polling is driven by hand here, so nothing waits for a timer.
@MainActor @Suite struct QACommandRouteTests {
    @MainActor final class Recorder {
        var ran: [String] = []
        var qaLines: [String] = []
    }

    @MainActor final class FakeQAPlugin: PluginQACommands {
        static let manifest = PluginManifest(id: "qa", displayName: "QA", symbolName: "circle", order: 1)
        let recorder: Recorder
        init(recorder: Recorder) { self.recorder = recorder }
        init(context: PluginContext) { recorder = Recorder() }
        func runQACommand(_ line: String) async -> String {
            recorder.qaLines.append(line)
            return line == "boom" ? "error: boom" : "ok"
        }
    }

    private func rig(replay: Bool = false, existing: String = "") throws -> (QACommandRoute, URL, Recorder) {
        let file = FileManager.default.temporaryDirectory.appending(path: "qa-commands-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: file.path, contents: Data(existing.utf8))
        let recorder = Recorder()
        let plugin = FakeQAPlugin(recorder: recorder)
        let route = QACommandRoute(
            file: file, replay: replay,
            commands: {
                [
                    PluginCommand(id: "windows.workspace.2", title: "Go", run: { recorder.ran.append("workspace.2") }),
                    PluginCommand(id: "windows.toggleLayout", title: "Toggle", run: { recorder.ran.append("toggle") }),
                ]
            },
            qaPlugin: { $0 == "windows" ? plugin : nil })
        return (route, file, recorder)
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try handle.close()
    }

    private func logLines(_ file: URL) -> [String] {
        let text = (try? String(contentsOf: file.appendingPathExtension("log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    @Test func linesRunInOrderAndEveryResultIsLogged() async throws {
        let (route, file, recorder) = try rig()
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("log"))
        }
        try append(
            "# a comment\n\nwindows.workspace.2\nwindows.toggleLayout\nnope\nqa windows resetState\nqa windows boom\nqa other x\n",
            to: file)
        await route.pollOnce()
        #expect(recorder.ran == ["workspace.2", "toggle"])
        #expect(recorder.qaLines == ["resetState", "boom"])
        #expect(
            logLines(file) == [
                "ok | windows.workspace.2", "ok | windows.toggleLayout", "error: unknown command | nope",
                "ok | qa windows resetState", "error: boom | qa windows boom",
                "error: no such plugin or verb | qa other x",
            ])
    }

    /// QA round 3: a relaunch replayed the whole earlier run. The route starts at the end of the file unless the run
    /// asks to replay it (`--qa-command-replay`).
    @Test func aRelaunchStartsAtTheEndOfTheFileUnlessReplayIsAsked() async throws {
        let old = "windows.workspace.2\nwindows.toggleLayout\n"
        let (fresh, file, recorder) = try rig(existing: old)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("log"))
        }
        fresh.prepare()
        await fresh.pollOnce()
        #expect(recorder.ran.isEmpty)
        try append("windows.toggleLayout\n", to: file)
        await fresh.pollOnce()
        #expect(recorder.ran == ["toggle"])

        let (replaying, other, again) = try rig(replay: true, existing: old)
        defer {
            try? FileManager.default.removeItem(at: other)
            try? FileManager.default.removeItem(at: other.appendingPathExtension("log"))
        }
        replaying.prepare()
        await replaying.pollOnce()
        #expect(again.ran == ["workspace.2", "toggle"])
        let options = try #require(try QAOptions.parse(["--qa-command-file", "/tmp/c", "--qa-command-replay"]))
        #expect(options.replaysCommands)
    }

    @Test func aPartialLineWaitsForItsNewlineAndNothingRunsTwice() async throws {
        let (route, file, recorder) = try rig()
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("log"))
        }
        try append("windows.workspa", to: file)
        await route.pollOnce()
        #expect(recorder.ran.isEmpty)
        try append("ce.2\n", to: file)
        await route.pollOnce()
        await route.pollOnce()
        #expect(recorder.ran == ["workspace.2"])
        try append("windows.toggleLayout\n", to: file)
        await route.pollOnce()
        #expect(recorder.ran == ["workspace.2", "toggle"])
    }

    @Test func aFileThatWasEmptiedIsReadFromItsStartAgainAndOnlyTheNewPartIsRead() async throws {
        let (route, file, recorder) = try rig()
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("log"))
        }
        try append("windows.workspace.2\nwindows.toggleLayout\n", to: file)
        await route.pollOnce()
        #expect(recorder.ran == ["workspace.2", "toggle"])
        // Truncated, then a shorter line written: it is read from the start, once.
        try Data().write(to: file)
        try append("windows.toggleLayout\n", to: file)
        await route.pollOnce()
        await route.pollOnce()
        #expect(recorder.ran == ["workspace.2", "toggle", "toggle"])
    }

    @Test func theLogIsRotatedPastItsLimit() async throws {
        let (route, file, _) = try rig()
        let log = file.appendingPathExtension("log")
        defer {
            for url in [file, log, log.appendingPathExtension("1")] { try? FileManager.default.removeItem(at: url) }
        }
        try Data(repeating: UInt8(ascii: "x"), count: QACommandRoute.logLimit + 10).write(to: log)
        try append("windows.toggleLayout\n", to: file)
        await route.pollOnce()
        #expect(FileManager.default.fileExists(atPath: log.appendingPathExtension("1").path))
        #expect(logLines(file) == ["ok | windows.toggleLayout"])
    }

    @Test func theArgumentParsesAndTheRouteIsSetOnlyByTheQAEnvironment() throws {
        let options = try #require(try QAOptions.parse(["--qa-command-file", "/tmp/cmds.txt"]))
        #expect(options.commandFile?.path == "/tmp/cmds.txt")
        // Only `AppEnvironment.qa` assigns it: the assignment is inside that function's body and nowhere else in the
        // app target (a line-based scan, not a string count).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appending(path: "Sources/LintelApp")
        var assignmentSites: [String] = []
        for file in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap({
            $0 as? URL
        })
            ?? []
        where file.pathExtension == "swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.range(of: #"\bqaCommandFile\s*="#, options: .regularExpression) != nil {
                assignmentSites.append("\(file.lastPathComponent):\(index)")
            }
        }
        #expect(assignmentSites.count == 1)
        let environment = try String(contentsOf: sources.appending(path: "AppEnvironment.swift"), encoding: .utf8)
        let qaBody = try #require(
            environment.range(of: "static func qa(").flatMap { start in
                environment.range(of: "static func qaFileIndexSettings", range: start.upperBound..<environment.endIndex)
                    .map { String(environment[start.lowerBound..<$0.lowerBound]) }
            })
        #expect(qaBody.contains("qaEnvironment.qaCommandFile = options.commandFile"))
    }
}
#endif
