import AppKit
import Foundation
import Testing

@testable import WindowsPlugin

/// QA D3 and D5: the Layouts window has a sane default and minimum size, a remembered frame is made usable, and the
/// frame is kept in the plugin's settings, never in the window system's autosave (which writes to the real defaults
/// domain even in a QA run).
@Suite(.timeLimit(.minutes(1))) @MainActor struct LayoutsWindowFrameTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1079)

    @Test func aStoredFrameIsKeptWhenItIsUsable() {
        let stored = NSStringFromRect(NSRect(x: 100, y: 100, width: 1000, height: 700))
        #expect(
            LayoutsWindowController.usableFrame(stored, screens: [screen])
                == NSRect(x: 100, y: 100, width: 1000, height: 700))
    }

    @Test func aStoredFrameThatIsTooBigOrTooSmallIsClamped() {
        // The size QA saw the window open with: larger than the screen's height allows.
        let huge = LayoutsWindowController.usableFrame(
            NSStringFromRect(NSRect(x: 0, y: 0, width: 1265, height: 1362)), screens: [screen])
        #expect(huge?.height == screen.height)
        let tiny = LayoutsWindowController.usableFrame(
            NSStringFromRect(NSRect(x: 50, y: 50, width: 100, height: 100)), screens: [screen])
        #expect(tiny?.size == LayoutsWindowController.minimumSize)
    }

    @Test func aFrameOnADisconnectedScreenOrGarbageIsIgnored() {
        #expect(
            LayoutsWindowController.usableFrame(
                NSStringFromRect(NSRect(x: 9000, y: 9000, width: 900, height: 600)), screens: [screen]) == nil)
        #expect(LayoutsWindowController.usableFrame("not a frame", screens: [screen]) == nil)
    }

    @Test func theDefaultSizeIsAboveTheMinimumAndSane() {
        let size = LayoutsWindowController.defaultSize
        let minimum = LayoutsWindowController.minimumSize
        #expect(size.width >= minimum.width && size.height >= minimum.height)
        #expect(size.width <= 1200 && size.height <= 800)
    }

    @Test func theFrameGoesToThePluginSettingsAndNotTheDefaultsDomain() throws {
        let key = "NSWindow Frame WindowsLayouts"
        let before = UserDefaults.standard.object(forKey: key)
        var saved: [String] = []
        let controller = LayoutsWindowController(
            makeModel: { nil }, loadFrame: { nil }, saveFrame: { saved.append($0) })
        controller.close()
        #expect(UserDefaults.standard.object(forKey: key) as? String == before as? String)
        #expect(saved.isEmpty)
    }

    /// A lint over the plugin's sources: no window of the plugin may use the window system's own frame autosave.
    @Test func noWindowOfThePluginUsesTheWindowSystemsFrameAutosave() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/WindowsPlugin")
        let files =
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !text.contains("setFrameAutosaveName"), "\(file.lastPathComponent) uses the window system's autosave")
            #expect(!text.contains("frameAutosaveName"), "\(file.lastPathComponent) uses the window system's autosave")
        }
    }
}
