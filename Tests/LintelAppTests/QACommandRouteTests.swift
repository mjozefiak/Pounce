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

    private func rig() throws -> (QACommandRoute, URL, Recorder) {
        let file = FileManager.default.temporaryDirectory.appending(path: "qa-commands-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let recorder = Recorder()
        let plugin = FakeQAPlugin(recorder: recorder)
        let route = QACommandRoute(
            file: file,
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

    @Test func theArgumentParsesAndTheRouteIsSetOnlyByTheQAEnvironment() throws {
        let options = try #require(try QAOptions.parse(["--qa-command-file", "/tmp/cmds.txt"]))
        #expect(options.commandFile?.path == "/tmp/cmds.txt")
        // Only `AppEnvironment.qa` assigns it (a lint: nothing in a normal launch path can turn the route on).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appending(path: "Sources/LintelApp")
        var assignments = 0
        for file in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap({
            $0 as? URL
        })
            ?? []
        where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            assignments += text.components(separatedBy: "qaCommandFile = ").count - 1
        }
        #expect(assignments == 1)
    }
}
#endif
