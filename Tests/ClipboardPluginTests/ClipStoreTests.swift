import Foundation
import GRDB
import PounceKit
import Testing

@testable import ClipboardPlugin

@Suite final class ClipStoreTests {
    let temporary: TemporaryDirectory
    let store: ClipStore

    init() throws {
        temporary = try TemporaryDirectory()
        store = try ClipStore.open(in: temporary.url, keys: try testKeys())
    }

    deinit {
        try? store.close()
    }

    var blobFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: store.blobsDirectory.path)) ?? []
    }

    @Test(arguments: ClipKind.allCases)
    func storesAndReadsEveryKind(kind: ClipKind) throws {
        let items = [
            PasteboardItem(representations: [
                PasteboardRepresentation(type: "public.utf8-plain-text", data: Data("fake \(kind.rawValue)".utf8)),
                PasteboardRepresentation(type: "public.html", data: Data("<i>fake</i>".utf8)),
            ]),
            PasteboardItem(representations: [
                PasteboardRepresentation(type: "public.file-url", data: Data("file:///tmp/fake.txt".utf8))
            ]),
        ]
        guard case .inserted(let id) = try store.insert(draft("fake \(kind.rawValue)", kind: kind, items: items)) else {
            Issue.record("expected an insert")
            return
        }
        let detail = try #require(try store.detail(id))
        #expect(detail.summary.kind == kind)
        #expect(detail.previewText == "fake \(kind.rawValue)")
        #expect(detail.summary.sourceBundleID == "com.example.editor")
        #expect(detail.items == items)
    }

    @Test func accessAfterCloseThrowsInsteadOfCrashing() throws {
        try store.insert(draft("before close"))
        try store.close()
        #expect(throws: ClipStoreError.closed) { try store.count() }
        #expect(throws: ClipStoreError.closed) { try store.insert(draft("after close")) }
        try store.close()
    }

    @Test func aDuplicateMovesTheEntryToTheTopInsteadOfANewRow() throws {
        let first = try store.insert(draft("fake one", at: Date(timeIntervalSince1970: 100)))
        try store.insert(draft("fake two", at: Date(timeIntervalSince1970: 200)))
        #expect(try store.recent(limit: 10).map(\.previewText) == ["fake two", "fake one"])

        let again = try store.insert(draft("fake one", at: Date(timeIntervalSince1970: 300)))
        guard case .inserted(let id) = first, case .duplicate(let duplicate) = again else {
            Issue.record("expected insert then duplicate")
            return
        }
        #expect(id == duplicate)
        #expect(try store.count() == 2)
        #expect(try store.recent(limit: 10).map(\.previewText) == ["fake one", "fake two"])
    }

    @Test func theContentHashIsAKeyedHMACNotAPlainDigest() throws {
        let items = [textItem("fake")]
        let other = try ClipStore.open(in: temporary.url.appending(path: "other"), keys: try testKeys(42))
        defer { try? other.close() }
        #expect(store.contentHash(items) != other.contentHash(items))
        #expect(store.contentHash(items) == store.contentHash(items))
        #expect(store.contentHash(items).count == 32)
        // The same bytes split differently between items hash differently.
        let split = [textItem("fa"), textItem("ke")]
        #expect(store.contentHash(split) != store.contentHash([textItem("fake")]))
    }

    @Test func largeRepresentationsGoToEncryptedBlobFilesWithRandomNames() throws {
        let marker = Data("pounce-fake-blob-marker".utf8)
        let big = marker + Data(repeating: 0x41, count: ClipStore.inlineLimit + 1)
        let item = PasteboardItem(representations: [PasteboardRepresentation(type: "public.tiff", data: big)])
        guard case .inserted(let id) = try store.insert(draft("1 × 1", kind: .image, items: [item])) else {
            Issue.record("expected an insert")
            return
        }
        let files = blobFiles
        #expect(files.count == 1)
        let name = try #require(files.first)
        #expect(UUID(uuidString: name) != nil)
        let raw = try Data(contentsOf: store.blobURL(name))
        #expect(raw.range(of: marker) == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.blobURL(name).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        #expect(try store.detail(id)?.items.first?.data(for: "public.tiff") == big)

        try store.delete([id])
        #expect(blobFiles.isEmpty)
        #expect(try store.detail(id) == nil)
    }

    @Test func aTamperedBlobDoesNotDecrypt() throws {
        let big = Data(repeating: 0x42, count: ClipStore.inlineLimit + 10)
        let item = PasteboardItem(representations: [PasteboardRepresentation(type: "public.tiff", data: big)])
        guard case .inserted(let id) = try store.insert(draft("x", kind: .image, items: [item])) else {
            Issue.record("expected an insert")
            return
        }
        let url = store.blobURL(try #require(blobFiles.first))
        var raw = try Data(contentsOf: url)
        raw[raw.count - 1] ^= 0xFF
        try raw.write(to: url)
        #expect(throws: (any Error).self) { _ = try store.detail(id) }
    }

    @Test func fullTextSearchMatchesWordPrefixesAndDiacritics() throws {
        try store.insert(draft("fake meeting notes for Łódź", at: Date(timeIntervalSince1970: 1)))
        try store.insert(draft("fake shopping list", at: Date(timeIntervalSince1970: 2)))
        try store.insert(draft("https://example.com/meet", kind: .url, at: Date(timeIntervalSince1970: 3)))
        #expect(try store.search("meet", limit: 10).count == 2)
        #expect(try store.search("meet", limit: 10, kind: .url).map(\.kind) == [.url])
        // unicode61 folds accents (ó, ź) but not ł; the fuzzy layer over recent entries folds ł → l.
        #expect(try store.search("łodz", limit: 10).count == 1)
        #expect(try store.search("shop list", limit: 10).map(\.previewText) == ["fake shopping list"])
        #expect(try store.search("*", limit: 10).isEmpty)
    }

    @Test func recentFiltersByKind() throws {
        try store.insert(draft("fake text", at: Date(timeIntervalSince1970: 1)))
        try store.insert(draft("https://example.com", kind: .url, at: Date(timeIntervalSince1970: 2)))
        #expect(try store.recent(limit: 10, kind: .url).map(\.previewText) == ["https://example.com"])
        #expect(try store.recent(limit: 1).count == 1)
    }

    @Test func markUsedFeedsFrecency() throws {
        guard case .inserted(let id) = try store.insert(draft("fake", at: Date(timeIntervalSince1970: 1))) else {
            Issue.record("expected an insert")
            return
        }
        try store.markUsed(id, at: Date(timeIntervalSince1970: 50))
        let summary = try #require(try store.recent(limit: 1).first)
        #expect(summary.useCount == 1)
        #expect(summary.lastUsedAt == Date(timeIntervalSince1970: 50))
    }

    @Test func clearHistoryLeavesAnEmptyDatabaseAndAnEmptyBlobsFolder() throws {
        let big = Data(repeating: 1, count: ClipStore.inlineLimit + 1)
        try store.insert(
            draft("x", kind: .image, items: [PasteboardItem(representations: [.init(type: "public.tiff", data: big)])]))
        try store.insert(draft("fake searchable"))
        try store.deleteAll()
        #expect(try store.count() == 0)
        #expect(blobFiles.isEmpty)
        #expect(try store.search("searchable", limit: 10).isEmpty)
        let representations = try store.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM clip_representation")
        }
        #expect(representations == 0)
    }

    @Test func theOrphanSweepRemovesFilesWithoutARow() throws {
        let big = Data(repeating: 1, count: ClipStore.inlineLimit + 1)
        try store.insert(
            draft("x", kind: .image, items: [PasteboardItem(representations: [.init(type: "public.tiff", data: big)])]))
        FileManager.default.createFile(atPath: store.blobURL(UUID().uuidString).path, contents: Data("stray".utf8))
        #expect(blobFiles.count == 2)
        #expect(try store.sweepOrphans() == 1)
        #expect(blobFiles.count == 1)
    }

    @Test func theDatabaseIsEncrypted() throws {
        try store.insert(draft("pounce-fake-secret-marker"))
        let raw = try Data(contentsOf: temporary.url.appending(path: ClipStore.fileName))
        #expect(raw.range(of: Data("pounce-fake-secret-marker".utf8)) == nil)
        #expect(raw.range(of: Data("SQLite format 3".utf8)) == nil)
    }
}
