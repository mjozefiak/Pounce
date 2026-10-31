import AppKit
import Foundation
import PounceKit
import Testing
import os

@testable import ClipboardPlugin

@MainActor final class CaptureLog {
    var captures: [Capture] = []
}

@MainActor func makeWatcher(
    _ pasteboard: any PasteboardClient,
    workspace: FakeWorkspace = FakeWorkspace(),
    ignored: Set<String> = Set(CaptureFilter.defaultIgnoredApps),
    maximumBytes: Int = CaptureFilter.maximumEntryBytes,
    log: CaptureLog
) -> PasteboardWatcher {
    PasteboardWatcher(
        pasteboard: pasteboard,
        workspace: workspace,
        clock: ContinuousClock(),
        logger: Logger(subsystem: "app.pounce.tests", category: "clipboard"),
        filter: { CaptureFilter(ignoredApps: ignored, maximumBytes: maximumBytes) },
        onCapture: { log.captures.append($0) }
    )
}

/// Spike 2.2 and step 2.2: the watcher against a private named pasteboard.
@Suite @MainActor struct PasteboardWatcherTests {
    @Test func capturesANewStringWithItsSourceApp() throws {
        let pasteboard = NamedPasteboard()
        defer { pasteboard.release() }
        let log = CaptureLog()
        let watcher = makeWatcher(pasteboard, log: log)
        watcher.start()
        defer { watcher.stop() }
        #expect(!watcher.check())

        pasteboard.setString("fake copied text")
        #expect(watcher.check())
        #expect(watcher.lastEvent == .captured)
        let capture = try #require(log.captures.first)
        #expect(capture.source?.bundleIdentifier == "com.example.editor")
        #expect(capture.contents.items.first?.data(for: "public.utf8-plain-text") == Data("fake copied text".utf8))
        #expect(!watcher.check())
    }

    @Test func whatIsAlreadyThereAtStartIsNotCaptured() {
        let pasteboard = NamedPasteboard()
        defer { pasteboard.release() }
        pasteboard.setString("fake text from before")
        let log = CaptureLog()
        let watcher = makeWatcher(pasteboard, log: log)
        watcher.start()
        defer { watcher.stop() }
        #expect(!watcher.check())
        #expect(log.captures.isEmpty)
    }

    @Test(arguments: CaptureFilter.markerTypes.filter { !$0.contains(" ") })
    func markerTypesAreNeverCaptured(marker: String) {
        let pasteboard = NamedPasteboard()
        defer { pasteboard.release() }
        let log = CaptureLog()
        let watcher = makeWatcher(pasteboard, log: log)
        watcher.start()
        defer { watcher.stop() }
        pasteboard.writeTypes(["public.utf8-plain-text": Data("fake-password".utf8), marker: Data()])
        watcher.check()
        #expect(watcher.lastEvent == .skipped(.markerType))
        #expect(log.captures.isEmpty)
    }

    @Test(arguments: CaptureFilter.defaultIgnoredApps)
    func ignoredAppsAreNeverCaptured(bundleID: String) {
        let pasteboard = NamedPasteboard()
        defer { pasteboard.release() }
        let workspace = FakeWorkspace()
        workspace.frontmost = RunningApplication(processIdentifier: 9, bundleIdentifier: bundleID, name: "Vault")
        let log = CaptureLog()
        let watcher = makeWatcher(pasteboard, workspace: workspace, log: log)
        watcher.start()
        defer { watcher.stop() }
        pasteboard.setString("fake secret")
        watcher.check()
        #expect(watcher.lastEvent == .skipped(.ignoredApp))
        #expect(log.captures.isEmpty)
    }

    @Test func entriesOverTheLimitAreSkipped() {
        let pasteboard = NamedPasteboard()
        defer { pasteboard.release() }
        let log = CaptureLog()
        let watcher = makeWatcher(pasteboard, maximumBytes: 64, log: log)
        watcher.start()
        defer { watcher.stop() }
        pasteboard.setString(String(repeating: "x", count: 65))
        watcher.check()
        #expect(watcher.lastEvent == .skipped(.tooLarge))
        #expect(log.captures.isEmpty)
    }

    @Test func pounceOwnWritesAreNotCapturedAgain() {
        let pasteboard = NamedPasteboard()
        defer { pasteboard.release() }
        let log = CaptureLog()
        let watcher = makeWatcher(pasteboard, log: log)
        watcher.start()
        defer { watcher.stop() }
        watcher.ignore(changeCount: pasteboard.setString("fake pasted from history"))
        watcher.check()
        #expect(watcher.lastEvent == .ownWrite)
        #expect(log.captures.isEmpty)
    }

    /// The edge case "Schowek zmienił się ponownie w trakcie odczytu": the read is dropped and the
    /// newer contents are captured on the next poll.
    @Test func aChangeDuringTheReadDropsItAndTheNextPollTakesTheNewerContents() throws {
        let base = NamedPasteboard()
        defer { base.release() }
        let pasteboard = ChangingPasteboard(base: base)
        let log = CaptureLog()
        let watcher = makeWatcher(pasteboard, log: log)
        watcher.start()
        defer { watcher.stop() }

        base.setString("fake first")
        pasteboard.replacement = "fake second"
        watcher.check()
        #expect(watcher.lastEvent == .changedDuringRead)
        #expect(log.captures.isEmpty)

        watcher.check()
        #expect(watcher.lastEvent == .captured)
        let text = try #require(log.captures.first?.contents.items.first?.data(for: "public.utf8-plain-text"))
        #expect(String(decoding: text, as: UTF8.self) == "fake second")
    }

    @Test func aStoppedWatcherDoesNotPoll() async throws {
        let pasteboard = NamedPasteboard()
        defer { pasteboard.release() }
        let log = CaptureLog()
        let watcher = makeWatcher(pasteboard, log: log)
        watcher.start()
        #expect(watcher.isRunning)
        watcher.stop()
        #expect(!watcher.isRunning)
        pasteboard.setString("fake after stop")
        try await Task.sleep(for: .milliseconds(700))
        #expect(log.captures.isEmpty)
    }

    @Test func aRunningWatcherPollsOnItsOwn() async throws {
        let pasteboard = NamedPasteboard()
        defer { pasteboard.release() }
        let log = CaptureLog()
        let watcher = makeWatcher(pasteboard, log: log)
        watcher.start()
        defer { watcher.stop() }
        pasteboard.setString("fake polled")
        for _ in 0..<40 where log.captures.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(log.captures.count == 1)
    }
}

@Suite struct ClipClassifierTests {
    func item(_ values: [(String, String)]) -> PasteboardItem {
        PasteboardItem(representations: values.map { PasteboardRepresentation(type: $0.0, data: Data($0.1.utf8)) })
    }

    func classify(_ items: [PasteboardItem]) -> (ClipKind, String)? {
        ClipClassifier.classify(items)
    }

    @Test func plainText() throws {
        let (kind, preview) = try #require(classify([item([("public.utf8-plain-text", "fake note")])]))
        #expect(kind == .text)
        #expect(preview == "fake note")
    }

    @Test func richTextKeepsThePlainPreview() throws {
        let (kind, preview) = try #require(
            classify([item([("public.html", "<b>fake</b> bold"), ("public.utf8-plain-text", "fake bold")])]))
        #expect(kind == .rich)
        #expect(preview == "fake bold")
    }

    @Test func rtfWithoutPlainTextIsReadFromTheRTF() throws {
        let rtf = #"{\rtf1\ansi fake rich}"#
        let (kind, preview) = try #require(classify([item([("public.rtf", rtf)])]))
        #expect(kind == .rich)
        #expect(preview.contains("fake rich"))
    }

    @Test func aSingleWebAddressIsALink() throws {
        let (kind, preview) = try #require(classify([item([("public.utf8-plain-text", " https://example.com/a ")])]))
        #expect(kind == .url)
        #expect(preview == "https://example.com/a")
        #expect(ClipClassifier.webURL("see https://example.com") == nil)
        #expect(ClipClassifier.webURL("ftp://example.com") == nil)
    }

    @Test func filesListTheirPaths() throws {
        let items = [
            item([("public.file-url", "file:///tmp/fake-a.txt")]),
            item([("public.file-url", "file:///tmp/fake-b.pdf")]),
        ]
        let (kind, preview) = try #require(classify(items))
        #expect(kind == .file)
        #expect(preview == "/tmp/fake-a.txt\n/tmp/fake-b.pdf")
    }

    @Test func imagesReportTheirSize() throws {
        let png = try fakePNG(width: 3, height: 2)
        let items = [PasteboardItem(representations: [PasteboardRepresentation(type: "public.png", data: png)])]
        let (kind, preview) = try #require(classify(items))
        #expect(kind == .image)
        #expect(preview == "3 × 2")
    }

    @Test func dynamicAndMarkerTypesAreDroppedAndOpaqueEntriesSkipped() throws {
        let contents = PasteboardContents(changeCount: 1, items: [item([("dyn.ah62d4rv4gu8yc6durvwwaz", "x")])])
        #expect(ClipClassifier.draft(from: contents, source: nil, capturedAt: Date()) == nil)

        let text = PasteboardContents(
            changeCount: 2,
            items: [item([("public.utf8-plain-text", "fake"), ("dyn.abc", "private")])]
        )
        let kept = try #require(ClipClassifier.draft(from: text, source: nil, capturedAt: Date()))
        #expect(kept.items.first?.types == ["public.utf8-plain-text"])
    }
}

/// A tiny generated PNG (no fixture files, no real images).
func fakePNG(width: Int, height: Int) throws -> Data {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let data = bitmap.representation(using: .png, properties: [:])
    else { throw TestFailure.keys }
    return data
}
