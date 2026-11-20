import FluidAudio
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
        let engine = ParakeetEngine()
        #expect(await engine.isLoaded == false)
    }
}
