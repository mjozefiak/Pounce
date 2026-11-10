import Foundation
import GRDB
import LintelKit
import LintelSpeech
import Testing

@testable import NotesPlugin

@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesLogTests {
    @Test func errorCodesAreStable() {
        #expect(NotesError.keyUnavailable.code == "keyUnavailable")
        #expect(NotesError.schemaNewer.code == "schemaNewer")
        #expect(NotesError.readOnly.code == "readOnly")
        #expect(NotesError.casConflict.code == "casConflict")
        #expect(NotesError.guardRejected(rule: "images").code == "guardRejected(images)")
        #expect(NotesError.lockTimeout.code == "lockTimeout")
        #expect(NotesError.sourceUnavailable(pluginID: "meetings").code == "sourceUnavailable(meetings)")
        #expect(NotesError.migrationFailed(step: "v1-notes").code == "migrationFailed(v1-notes)")
    }

    @Test func aRunOverSensitiveFixturesLogsNoFixtureString() throws {
        let harness = try NotesHarness()
        let secrets = ["Quarterly layoffs", "Maria Kowalska", "diagnosis", "meetings:secret-meeting-uuid"]
        let opener = harness.opener()
        opener.open()
        let store = try #require(opener.store)
        let doc = try store.insertDocument(
            .manual("secret-note", body: "Maria Kowalska has a diagnosis", title: "Quarterly layoffs"))
        _ = try store.search("diagnosis")
        try store.insertDocument(.overlay("secret-meeting-uuid", body: "Maria Kowalska"))
        try store.detach(NoteKey(pluginID: "meetings", id: "secret-meeting-uuid"))
        try store.deleteDocument(doc.docID)
        harness.keychain.failReads(with: .accessDenied)
        opener.close()
        harness.opener().open()
        try opener.erase()
        // Events that carry a key log only its hash.
        harness.log.log(NotesLogEvent("detach", code: "x", count: 1, durationMs: 2, key: secrets[3]), isError: false)

        let lines = harness.log.all
        #expect(!lines.isEmpty)
        for line in lines {
            for secret in secrets { #expect(!line.contains(secret), "\(line) leaks \(secret)") }
        }
        let hash = NotesLog.hashedKey(secrets[3])
        #expect(lines.last == "detach code=x count=1 ms=2 key=\(hash)")
        #expect(hash.count == 8)
        #expect(hash != NotesLog.hashedKey("meetings:other"))
    }

    @Test func theLoggerUsesTheDocumentedSubsystemAndCategory() {
        #expect(OSNotesLog.subsystem == "com.lintelapp")
        #expect(OSNotesLog.category == "notes")
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesSettingsTests {
    @Test func defaultsFollowTheSpec() throws {
        let settings = try NotesHarness().notesSettings
        #expect(settings.grouping == .time)
        #expect(settings.showAuthorBars)
        #expect(settings.showQuotes)
        #expect(settings.showComments)
        #expect(settings.wrapLines)
        #expect(!settings.readOnly)
        #expect(settings.storedModelID == nil)
    }

    @Test func storedValuesAreRead() throws {
        let harness = try NotesHarness()
        harness.settings.set("source", for: NotesSettingsKey.grouping)
        harness.settings.set(false, for: NotesSettingsKey.wrapLines)
        harness.settings.set(true, for: NotesSettingsKey.readOnly)
        #expect(harness.notesSettings.grouping == .source)
        #expect(!harness.notesSettings.wrapLines)
        #expect(harness.notesSettings.readOnly)
        harness.settings.set("nonsense", for: NotesSettingsKey.grouping)
        #expect(harness.notesSettings.grouping == .time)
    }

    @Test func theKeysAreTheDocumentedOnes() {
        #expect(NotesSettingsKey.grouping == "grouping")
        #expect(NotesSettingsKey.showAuthorBars == "showAuthorBars")
        #expect(NotesSettingsKey.showQuotes == "showQuotes")
        #expect(NotesSettingsKey.showComments == "showComments")
        #expect(NotesSettingsKey.wrapLines == "wrapLines")
        #expect(NotesSettingsKey.builtInLLMModel == "builtInLLMModel")
        #expect(NotesSettingsKey.readOnly == "readOnly")
    }

    @Test func everyProductionKeyIsListedInTheCompatibilityDocument() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: "BACKWARD_COMPATIBILITY.md"), encoding: .utf8)
        for key in [
            "grouping", "showAuthorBars", "showQuotes", "showComments", "wrapLines", "builtInLLMModel", "readOnly",
        ] {
            #expect(
                text.contains("plugins.notes.\(key)"), "plugins.notes.\(key) is missing in BACKWARD_COMPATIBILITY.md")
        }
        #expect(text.contains("com.lintelapp.notes"))
        #expect(text.contains("v1-notes"))
    }

    @Test func theModelRuleIsOneRuleForTheKeyAndTheDefault() throws {
        let harness = try NotesHarness()
        let large = LLMModelCatalog.qwen3Large
        let small = LLMModelCatalog.qwen3Small
        // Nothing stored, nothing installed: the catalog default.
        #expect(harness.notesSettings.builtInLLMModel(installedIDs: []) == LLMModelCatalog.defaultModel)
        // Nothing stored: the first installed one.
        #expect(harness.notesSettings.builtInLLMModel(installedIDs: [large.id]) == large)
        // A stored id in the catalog wins; one that left the catalog falls back to the rule.
        harness.settings.set(small.id, for: NotesSettingsKey.builtInLLMModel)
        #expect(harness.notesSettings.builtInLLMModel(installedIDs: [large.id]) == small)
        harness.settings.set("gone-from-catalog", for: NotesSettingsKey.builtInLLMModel)
        #expect(harness.notesSettings.builtInLLMModel(installedIDs: [large.id]) == large)
    }
}
