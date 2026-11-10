import Foundation
import LintelKit
import Synchronization
import Testing

@testable import NotesPlugin

/// Edit mode on a recorded note opens no library (lazy-store rule, ADR 0008 addendum): the Keychain item and
/// `notes.sqlite` appear at the first real write (the first typed character, a comment or a save), and from then
/// on the writer behaves exactly as with an eager store.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LazyEditStoreTests {
    private let key = NoteKey(pluginID: "meetings", id: "lazy-1")
    private let started = Date(timeIntervalSince1970: 1_800_000_000)

    private func content() -> NoteContent {
        NoteContent(
            summary: NoteSummary(id: key, kind: .meeting, title: "t", startedAt: started, state: .ready),
            layers: [NoteLayer(id: "notes", author: .agent, markdown: "agent text", provenance: [], version: "v1")],
            speakers: [])
    }

    private struct Rig {
        let plugin: NotesPlugin
        let storage: URL
        let keychain: CountingKeychain
    }

    private func rig() -> Rig {
        let storage = FileManager.default.temporaryDirectory.appending(
            path: "lintel-notes-lazy-\(UUID().uuidString)", directoryHint: .isDirectory)
        let keychain = CountingKeychain()
        return Rig(
            plugin: NotesPlugin(context: makeContext(storage: storage, keychain: keychain)), storage: storage,
            keychain: keychain)
    }

    private func session(_ r: Rig) throws -> NoteEditingSession {
        let document = NoteDocumentModel(id: .live(key))
        return try #require(r.plugin.workspace.environment.makeEditingSession(content(), "notes", document))
    }

    private func edit(_ text: String) -> NoteEditorEdit {
        NoteEditorEdit(text: text, range: 0..<text.utf16.count, changeInLength: text.utf16.count)
    }

    // MARK: The profile stays untouched

    @Test func enteringAndLeavingEditModeOnAFreshProfileCreatesNoKeychainItemAndNoFile() async throws {
        let r = rig()
        defer { try? FileManager.default.removeItem(at: r.storage) }
        let session = try session(r)
        #expect(session.isEditable)
        // Leaving: blur, tab close and the mode switch are save points with nothing typed.
        #expect(await session.flush() == .nothing)
        #expect(await session.flush(closingSession: true) == .nothing)
        #expect(r.keychain.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: r.storage.path))
        #expect(r.plugin.library.store == nil)
    }

    @Test func theFirstTypedCharacterCreatesTheLibraryAndSavesAtTabClose() async throws {
        let r = rig()
        defer { try? FileManager.default.removeItem(at: r.storage) }
        let session = try session(r)
        session.handle(edit("agent text!"))
        #expect(r.keychain.calls == 0)  // typing alone only buffers
        let outcome = await session.flush(closingSession: true)  // tab close
        guard case .seeded(let docID, _) = outcome else {
            Issue.record("expected a seed, got \(outcome)")
            return
        }
        #expect(r.keychain.calls > 0)
        let store = try #require(r.plugin.library.store)
        #expect(try store.headRevision(of: docID)?.body == "agent text!")
        #expect(try store.liveDocument(key: key, layer: "notes")?.id == docID)
        await r.plugin.deactivate()
    }

    @Test func aCommentOnAFreshProfileOpensTheLibraryAndSeedsTheOverlay() async throws {
        let r = rig()
        defer { try? FileManager.default.removeItem(at: r.storage) }
        let session = try session(r)
        #expect(session.canComment)
        let threadID = try await session.addComment(
            body: "check", selection: NSRange(location: 0, length: 5), buffer: "agent text")
        let store = try #require(r.plugin.library.store)
        let document = try #require(try store.liveDocument(key: key, layer: "notes"))
        #expect(try store.headRevision(of: document.id)?.body == "agent text")
        #expect(threadID > 0)
        await r.plugin.deactivate()
    }

    // MARK: The writer, with an injected clock

    private final class Opens: Sendable {
        private let state = Mutex(0)
        var count: Int { state.withLock { $0 } }
        func hit() { state.withLock { $0 += 1 } }
    }

    private func lazyWriter(_ rig: DocRig, opens: Opens) throws -> RevisionWriter {
        let store = rig.store
        let plan = try rig.plan(rig.layer("seed text"))
        return RevisionWriter(
            storeProvider: {
                opens.hit()
                return store
            }, target: .seed(plan), clock: rig.clock,
            observer: RevisionWriter.Observer(wrote: { [wrote = rig.wrote] _ in wrote.increment() }),
            log: rig.log)
    }

    @Test func theDebouncedAutosaveOpensTheStoreOnceAndWrites() async throws {
        let rig = try DocRig()
        let opens = Opens()
        let writer = try lazyWriter(rig, opens: opens)
        writer.submit("a")
        writer.submit("ab")
        await rig.clock.waitForSleeps(3)
        #expect(opens.count == 0)  // buffered only
        rig.clock.advance(by: .seconds(1))
        await rig.wrote.wait()
        #expect(opens.count == 1)
        let docID = try #require(await writer.docID)
        #expect(try rig.head(docID).body == "ab")
        writer.submit("abc")
        _ = try await writer.flush()
        #expect(opens.count == 1)  // opened once, then reused
        #expect(try rig.head(docID).body == "abc")
    }

    @Test func theMaxWaitAutosaveOpensTheStoreAndWrites() async throws {
        let rig = try DocRig()
        let opens = Opens()
        let writer = try lazyWriter(rig, opens: opens)
        writer.submit("k0")
        await rig.clock.waitForSleeps(2)
        for index in 1...8 {  // a key every 600 ms: the 1 s debounce never fires
            rig.clock.advance(by: .milliseconds(600))
            writer.submit("k\(index)")
            await rig.clock.waitForSleeps(2 + index)
        }
        #expect(opens.count == 0)
        rig.clock.advance(by: .milliseconds(200))
        await rig.wrote.wait()
        #expect(opens.count == 1)
        let docID = try #require(await writer.docID)
        #expect(try rig.head(docID).body == "k8")
    }

    @Test func aFlushWithNothingTypedNeverOpensTheStore() async throws {
        let rig = try DocRig()
        let opens = Opens()
        let writer = try lazyWriter(rig, opens: opens)
        #expect(try await writer.flush() == .nothing)
        await writer.closeSession()
        #expect(try await writer.flush(closingSession: true) == .nothing)
        #expect(opens.count == 0)
    }

    @Test func aCompareAndSetLossAfterALazyOpenIsKeptAsAProposal() async throws {
        let rig = try DocRig()
        let opens = Opens()
        let writer = try lazyWriter(rig, opens: opens)
        writer.submit("mine")
        _ = try await writer.flush()
        await writer.closeSession()
        let docID = try #require(await writer.docID)
        let intruder = try rig.store.appendRevision(
            NewNoteRevision(
                docID: docID, author: "agent", state: .applied, body: "intruder", now: Date(),
                expectedHeadID: try rig.head(docID).id))
        writer.submit("mine again")
        guard case .keptAsProposal(let proposal) = try await writer.flush() else {
            Issue.record("expected a proposal")
            return
        }
        #expect(try rig.store.revision(id: proposal)?.body == "mine again")
        #expect(try rig.head(docID).id == intruder)  // never auto-applied
    }

    @Test func aProviderThatCannotOpenKeepsTheTextForARetry() async throws {
        let rig = try DocRig()
        let writer = RevisionWriter(
            storeProvider: { nil }, target: .seed(try rig.plan(rig.layer("seed text"))), clock: rig.clock,
            log: rig.log)
        writer.submit("typed")
        await #expect(throws: NotesError.keyUnavailable) { try await writer.flush() }
        #expect(writer.hasPendingText)
    }
}
