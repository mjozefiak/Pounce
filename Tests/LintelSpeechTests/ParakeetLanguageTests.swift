import FluidAudio
import Foundation
import Synchronization
import Testing

@testable import LintelSpeech

@Suite struct ParakeetLanguageTests {
    @Test func settingsCodesMapToScriptHints() {
        #expect(ParakeetLanguage.hint(for: "pl") == .polish)
        #expect(ParakeetLanguage.hint(for: "en") == .english)
    }

    @Test func unknownOrMissingCodeSendsNoHint() {
        #expect(ParakeetLanguage.hint(for: nil) == nil)
        #expect(ParakeetLanguage.hint(for: "") == nil)
        #expect(ParakeetLanguage.hint(for: "xx") == nil)
    }

    @Test func engineDefaultsToNoHint() async {
        // Dictation builds `ParakeetEngine()` and must keep decoding exactly as before.
        #expect(await ParakeetEngine().languageHint == nil)
    }

    @Test func engineReadsTheLanguageForEverySegment() async {
        let code = Mutex<String?>("pl")
        let engine = ParakeetEngine(language: { code.withLock { $0 } })
        #expect(await engine.languageHint == .polish)
        code.withLock { $0 = "en" }
        #expect(await engine.languageHint == .english)
    }

    /// Dictation sends no hint (no owner decision for it yet); Meetings passes its Settings language.
    @Test func onlyMeetingsPassesALanguage() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        let dictation = try String(
            contentsOf: sources.appending(path: "DictationPlugin/DictationPlugin.swift"), encoding: .utf8)
        let meetings = try String(
            contentsOf: sources.appending(path: "MeetingsPlugin/MeetingsRuntime.swift"), encoding: .utf8)
        #expect(dictation.contains("ParakeetEngine()"))
        #expect(!dictation.contains("ParakeetEngine(language:"))
        #expect(meetings.contains("ParakeetEngine(language: { settings.speechLanguage })"))
    }
}
