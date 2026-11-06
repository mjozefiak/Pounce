import Foundation
import LintelKit
import Testing

@testable import MeetingsPlugin

/// Step 6.3c-fix-c: a test run once left a real recording HUD ("0:00 · Me · System · End recording") on the
/// owner's screen. No test may build the real HUDs, play the system-audio tone, reach Core Audio, ask for the
/// microphone or start a real recording: the plugin gets all of them from `MeetingsSystem`, and every test
/// support path installs `MeetingsSystem.quiet`.
@MainActor
@Suite struct NoRealSystemTests {
    /// The real parts, and the one file of the plugin allowed to build them.
    private static let realParts = [
        "MeetingHUDPanel(", "SuggestionHUDPanel(", "CoreAudioProcessObserver(", "AVAudioEngineTonePlayer(",
        "SystemMicrophoneAuthorizer(", "runtime.makeSession(",
    ]

    private static func code(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func swiftFiles(under path: String) -> [URL] {
        let folder = TestPaths.repoRoot.appending(path: path, directoryHint: .isDirectory)
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        return files
    }

    @Test func thePluginBuildsTheRealPartsOnlyThroughMeetingsSystem() throws {
        let files = TestPaths.meetingsSourceFiles()
        #expect(files.contains { $0.lastPathComponent == "MeetingsSystem.swift" })
        for url in files where url.lastPathComponent != "MeetingsSystem.swift" {
            let text = try Self.code(url)
            for part in Self.realParts {
                #expect(!text.contains(part), "\(url.lastPathComponent) builds \(part) outside MeetingsSystem")
            }
        }
        let system = try Self.code(TestPaths.meetingsSource(named: "MeetingsSystem.swift"))
        for part in Self.realParts {
            #expect(system.contains(part), "MeetingsSystem.live no longer builds \(part)")
        }
    }

    @Test func noTestBuildsARealPart() throws {
        let files = Self.swiftFiles(under: "Tests/MeetingsPluginTests") + Self.swiftFiles(under: "Tests/LintelAppTests")
        #expect(files.contains { $0.lastPathComponent == "QuietSystem.swift" })
        for url in files where url.lastPathComponent != "NoRealSystemTests.swift" {
            let text = try Self.code(url).replacingOccurrences(of: "MeetingsSystem.liveUses", with: "")
            for part in Self.realParts + ["MeetingsSystem.live", "system: .live"] {
                #expect(!text.contains(part), "\(url.lastPathComponent) uses \(part)")
            }
        }
    }

    /// The shell builds the plugin from its type; in the tests that goes through an environment that installs
    /// the quiet system first.
    @Test func everyShellTestEnvironmentInstallsTheQuietSystem() throws {
        for url in Self.swiftFiles(under: "Tests/LintelAppTests") {
            let text = try Self.code(url)
            guard text.contains("AppEnvironment(") else { continue }
            #expect(text.contains("QuietMeetings.install()"), "\(url.lastPathComponent) builds an environment")
        }
    }

    @Test func aPluginBuiltFromItsTypeRecordsOnlyWithFakes() async throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        #expect(plugin.system.makeHUD({ _ in }) is RecordingHUD)
        #expect(plugin.suggestionHUD is RecordingSuggestionPresenter)
        #expect(plugin.system.microphoneAuthorizer() is FakeAuthorizer)
        try await plugin.activate()
        // ⌃⌥M with no speech model: the HUD says so; it is the fake.
        let record = try #require(plugin.commands.first { $0.id == MeetingsUI.recordCommandID })
        await record.run()
        await eventually("the HUD shows the problem") { plugin.controller?.phase == .idle }
        await plugin.deactivate()
        #expect(MeetingsSystem.liveUses.isEmpty, "\(MeetingsSystem.liveUses.sorted())")
    }
}
