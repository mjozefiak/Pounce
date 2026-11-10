#if DEBUG
import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// The DEBUG-only QA switches that make a real-window QA run possible (`docs/qa.md`): the real Accessibility client
/// with every other isolation kept, a floating-app list, and settings that survive a relaunch inside the QA data root.
@Suite struct QAWindowOptionsTests {
    @Test func theNewArgumentsParse() throws {
        let options = try #require(
            try QAOptions.parse([
                "--qa-real-windows", "--qa-persistent-settings", "--qa-setting",
                "plugins.windows.floatingApps=com.apple.finder,com.example.app",
            ]))
        #expect(options.realWindows)
        #expect(options.persistentSettings)
        #expect(
            options.settings["plugins.windows.floatingApps"] == .stringArray(["com.apple.finder", "com.example.app"]))
        let plain = try #require(try QAOptions.parse(["--qa"]))
        #expect(!plain.realWindows && !plain.persistentSettings)
    }

    @Test func theRealClientIsSelectedOnlyWhenAskedAndTheRestOfTheIsolationStays() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lintel-qa-opts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var options = QAOptions()
        options.dataRoot = root
        let isolated = try AppEnvironment.qa(options)
        #expect(isolated.windowClient is NoWindowClient)
        options.fakeWindows = true
        #expect(try AppEnvironment.qa(options).windowClient is QAWindowClient)
        options.realWindows = true
        let real = try AppEnvironment.qa(options)
        #expect(real.windowClient is AXWindowClient)
        // Everything else is still the QA isolation: no hotkeys, a temporary data root, in-memory Keychain.
        #expect(!real.registersGlobalHotkeys)
        #expect(real.dataRoot == root)
        #expect(real.keychain is InMemoryKeychainClient)
    }

    @Test func persistentSettingsSurviveARelaunchAndCommandLineValuesWin() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lintel-qa-persist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var options = QAOptions()
        options.dataRoot = root
        options.persistentSettings = true
        let first = try AppEnvironment.qa(options)
        first.settings.setValue(.integer(1), forKey: "plugins.windows.parkedLaunches")
        first.settings.setValue(.stringArray(["a", "b"]), forKey: "plugins.windows.floatingApps")
        first.settings.setValue(.bool(true), forKey: "plugins.windows.safeMode")
        // The second launch reads them back; a value given on the command line replaces the stored one.
        options.settings["plugins.windows.parkedLaunches"] = .integer(5)
        let second = try AppEnvironment.qa(options)
        #expect(second.settings.value(forKey: "plugins.windows.parkedLaunches") == .integer(5))
        #expect(second.settings.value(forKey: "plugins.windows.floatingApps") == .stringArray(["a", "b"]))
        #expect(second.settings.value(forKey: "plugins.windows.safeMode") == .bool(true))
        // Without the switch nothing is kept: settings stay in memory.
        let memory = root.appending(path: "memory")
        var plain = QAOptions()
        plain.dataRoot = memory
        let one = try AppEnvironment.qa(plain)
        one.settings.setValue(.integer(9), forKey: "plugins.windows.parkedLaunches")
        #expect(try AppEnvironment.qa(plain).settings.value(forKey: "plugins.windows.parkedLaunches") == nil)
        #expect(!FileManager.default.fileExists(atPath: memory.appending(path: QAFileSettingsStore.fileName).path))
    }
}
#endif
