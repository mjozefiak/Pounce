import AppKit
import Foundation
import PounceKit

@testable import ClipboardPlugin

/// A `PasteboardClient` over a private `NSPasteboard(name:)`, so tests never read or write the real
/// clipboard. Mirrors the app's system client.
@MainActor final class NamedPasteboard: PasteboardClient {
    let pasteboard: NSPasteboard
    var access: PasteboardAccess = .alwaysAllow

    init() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("app.pounce.tests.clipboard.\(UUID().uuidString)"))
    }

    func release() {
        pasteboard.releaseGlobally()
    }

    var changeCount: Int { pasteboard.changeCount }
    func string() -> String? { pasteboard.string(forType: .string) }

    func setString(_ string: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        return pasteboard.changeCount
    }

    func types() -> [String] { pasteboard.types?.map(\.rawValue) ?? [] }

    /// Types whose data was requested by the last read.
    private(set) var requestedTypes: [String] = []

    func readContents(maxBytes: Int, including includes: (String) -> Bool) -> PasteboardContents? {
        let changeCount = pasteboard.changeCount
        requestedTypes = []
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        var total = 0
        var copied: [PasteboardItem] = []
        for item in items {
            var representations: [PasteboardRepresentation] = []
            for type in item.types where includes(type.rawValue) {
                requestedTypes.append(type.rawValue)
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > maxBytes {
                    return PasteboardContents(changeCount: changeCount, items: [], exceedsLimit: true)
                }
                representations.append(PasteboardRepresentation(type: type.rawValue, data: data))
            }
            copied.append(PasteboardItem(representations: representations))
        }
        return PasteboardContents(changeCount: changeCount, items: copied)
    }

    func write(_ items: [PasteboardItem]) -> Int {
        pasteboard.clearContents()
        pasteboard.writeObjects(
            items.map { item in
                let object = NSPasteboardItem()
                for representation in item.representations {
                    object.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
                }
                return object
            })
        return pasteboard.changeCount
    }

    var accessBehavior: PasteboardAccess { access }

    /// Writes raw types, for example a marker type next to a string.
    func writeTypes(_ values: [String: Data]) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in values {
            item.setData(data, forType: NSPasteboard.PasteboardType(type))
        }
        pasteboard.writeObjects([item])
    }
}

/// Wraps a pasteboard and replaces its contents in the middle of a read, like another app copying
/// again while Pounce reads.
@MainActor final class ChangingPasteboard: PasteboardClient {
    let base: NamedPasteboard
    var replacement: String?

    init(base: NamedPasteboard) {
        self.base = base
    }

    var changeCount: Int { base.changeCount }
    func string() -> String? { base.string() }
    func setString(_ string: String) -> Int { base.setString(string) }
    func types() -> [String] { base.types() }

    func readContents(maxBytes: Int, including includes: (String) -> Bool) -> PasteboardContents? {
        let contents = base.readContents(maxBytes: maxBytes, including: includes)
        if let replacement {
            self.replacement = nil
            base.setString(replacement)
        }
        return contents
    }
}

/// A workspace whose frontmost app is fixed by the test.
@MainActor final class FakeWorkspace: WorkspaceClient {
    var frontmost: RunningApplication? = RunningApplication(
        processIdentifier: 501, bundleIdentifier: "com.example.editor", name: "Editor")
    var running: Set<pid_t> = [501]
    var opened: [URL] = []

    nonisolated init() {}

    var frontmostApplicationPID: pid_t? { frontmost?.processIdentifier }
    func open(_ url: URL) async throws { opened.append(url) }
    func revealInFinder(_ urls: [URL]) {}
    var frontmostApplication: RunningApplication? { frontmost }

    func runningApplication(processIdentifier: pid_t) -> RunningApplication? {
        running.contains(processIdentifier) ? RunningApplication(processIdentifier: processIdentifier) : nil
    }
}
