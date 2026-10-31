import AppKit
import Foundation
import PounceKit
import Testing

@testable import PounceApp

/// The system pasteboard client against a private named pasteboard; the real clipboard is never read
/// or written.
@Suite @MainActor struct PasteboardClientTests {
    let name = NSPasteboard.Name("app.pounce.tests.\(UUID().uuidString)")

    @Test func writesAndReadsEveryItemAndRepresentation() throws {
        let client = SystemPasteboardClient(name: name)
        defer { NSPasteboard(name: name).releaseGlobally() }
        let before = client.changeCount
        let items = [
            PasteboardItem(representations: [
                PasteboardRepresentation(type: "public.utf8-plain-text", data: Data("fake one".utf8)),
                PasteboardRepresentation(type: "public.html", data: Data("<b>fake one</b>".utf8)),
            ]),
            PasteboardItem(representations: [
                PasteboardRepresentation(type: "public.file-url", data: Data("file:///tmp/fake.txt".utf8))
            ]),
        ]
        let after = client.write(items)
        #expect(after != before)
        #expect(client.changeCount == after)
        #expect(Set(client.types()).isSuperset(of: ["public.utf8-plain-text", "public.html", "public.file-url"]))

        let contents = try #require(client.readContents(maxBytes: 1 << 20))
        #expect(contents.changeCount == after)
        #expect(contents.items.count == 2)
        #expect(contents.items[0].data(for: "public.html") == Data("<b>fake one</b>".utf8))
        #expect(contents.items[1].data(for: "public.file-url") == Data("file:///tmp/fake.txt".utf8))
        #expect(!contents.exceedsLimit)
    }

    @Test func stopsAtTheByteLimit() throws {
        let client = SystemPasteboardClient(name: name)
        defer { NSPasteboard(name: name).releaseGlobally() }
        client.setString(String(repeating: "x", count: 100))
        let contents = try #require(client.readContents(maxBytes: 10))
        #expect(contents.exceedsLimit)
        #expect(contents.items.isEmpty)
    }

    @Test func readsOnlyTheIncludedTypes() throws {
        let client = SystemPasteboardClient(name: name)
        defer { NSPasteboard(name: name).releaseGlobally() }
        client.write([
            PasteboardItem(representations: [
                PasteboardRepresentation(type: "public.utf8-plain-text", data: Data("fake".utf8)),
                PasteboardRepresentation(type: "public.html", data: Data(repeating: 60, count: 64)),
            ])
        ])
        // The excluded HTML would exceed the 10-byte limit if it were read.
        let contents = try #require(client.readContents(maxBytes: 10) { $0 != "public.html" })
        #expect(!contents.exceedsLimit)
        #expect(contents.items.first?.types == ["public.utf8-plain-text"])
    }

    @Test func anEmptyPasteboardReadsAsNil() {
        let client = SystemPasteboardClient(name: name)
        defer { NSPasteboard(name: name).releaseGlobally() }
        NSPasteboard(name: name).clearContents()
        #expect(client.readContents(maxBytes: 100) == nil)
    }

    @Test func mapsAccessBehaviourAndHonoursTheQAOverride() {
        #expect(SystemPasteboardClient.access(.alwaysAllow) == .alwaysAllow)
        #expect(SystemPasteboardClient.access(.alwaysDeny) == .alwaysDeny)
        #expect(SystemPasteboardClient.access(.ask) == .ask)
        #expect(SystemPasteboardClient.access(.default) == .systemDefault)
        #expect(SystemPasteboardClient(name: name, accessOverride: .ask).accessBehavior == .ask)
    }
}
