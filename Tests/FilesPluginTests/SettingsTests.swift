import Foundation
import PounceKit
import Testing

@testable import FilesPlugin

@MainActor
@Suite("Files settings")
struct FilesSettingsTests {
    private func make(_ values: [String: SettingValue] = [:]) -> (FilesSettings, MemorySettings) {
        let store = MemorySettings(values)
        return (FilesSettings(PluginSettings(pluginID: "files", store: store), realHome: "/Users/tester"), store)
    }

    @Test func defaults() {
        let (settings, _) = make()
        #expect(settings.home == "/Users/tester")
        #expect(settings.displayedRoots == ["/Users/tester", "/Applications"])
        #expect(settings.usesDefaultRoots)
        #expect(!settings.setupCompleted)
        #expect(settings.includesICloudDrive)
        #expect(!settings.includesHidden)
        let plan = settings.plan(fullDiskAccess: false)
        #expect(plan.roots == ["/Users/tester", "/Applications"])
        #expect(plan.skippedProtectedPaths.contains("/Users/tester/Desktop"))
    }

    @Test func rootsAreStoredAbbreviatedAndDeduplicated() {
        let (settings, store) = make()
        var changes = 0
        settings.onChange = { changes += 1 }
        settings.addRoot("/Users/tester/Code")
        settings.addRoot("~/Code/")
        #expect(settings.displayedRoots == ["/Users/tester", "/Applications", "~/Code"])
        #expect(
            store.value(forKey: "plugins.files.roots") == .stringArray(["/Users/tester", "/Applications", "~/Code"]))
        settings.removeRoot("/Applications")
        #expect(settings.displayedRoots == ["/Users/tester", "~/Code"])
        settings.restoreDefaultRoots()
        #expect(settings.usesDefaultRoots)
        #expect(store.value(forKey: "plugins.files.roots") == nil)
        #expect(changes == 3)
    }

    @Test func exclusionsAndProtectedFoldersPersist() {
        let (settings, store) = make()
        settings.addExclusion("  *.log ")
        settings.addExclusion("*.log")
        settings.addExclusion("~/Scratch")
        #expect(settings.exclusions == ["*.log", "~/Scratch"])
        #expect(settings.rules().excludes(name: "debug.log", path: "/Users/tester/debug.log", hiddenFlag: false))
        #expect(settings.rules().excludes(name: "Scratch", path: "/Users/tester/Scratch", hiddenFlag: false))
        settings.removeExclusion("*.log")
        #expect(store.value(forKey: "plugins.files.exclusions") == .stringArray(["~/Scratch"]))

        settings.setProtected(.downloads, added: true)
        settings.setProtected(.desktop, added: true)
        #expect(store.value(forKey: "plugins.files.protectedFolders") == .stringArray(["desktop", "downloads"]))
        let plan = settings.plan(fullDiskAccess: false)
        #expect(plan.indexedProtected == [.desktop, .downloads])
        #expect(!plan.skippedProtectedPaths.contains("/Users/tester/Desktop"))
    }

    @Test func storedValuesAreRead() {
        let (settings, _) = make([
            "plugins.files.roots": .stringArray(["~/Work"]),
            "plugins.files.includeHidden": .bool(true),
            "plugins.files.icloud": .bool(false),
            "plugins.files.setupCompleted": .bool(true),
            "plugins.files.protectedFolders": .stringArray(["documents", "bogus"]),
        ])
        #expect(settings.displayedRoots == ["~/Work"])
        #expect(settings.includesHidden)
        #expect(!settings.includesICloudDrive)
        #expect(settings.setupCompleted)
        #expect(settings.addedProtected == [.documents])
        // An added folder that no root contains becomes a root.
        #expect(settings.plan(fullDiskAccess: true).roots == ["/Users/tester/Work", "/Users/tester/Documents"])
    }

    #if DEBUG
    @Test func qaHomeReplacesTheHomeFolder() {
        let (settings, _) = make(["plugins.files.qaHome": .string("/tmp/pounce-p3-fixture/home")])
        #expect(settings.home == "/tmp/pounce-p3-fixture/home")
        #expect(settings.displayedRoots.first == "/tmp/pounce-p3-fixture/home")
    }
    #endif
}
