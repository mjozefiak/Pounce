import Foundation
import Testing

@testable import DictationPlugin
@testable import LintelSpeech

@MainActor
@Suite struct EngineChoiceSettingsTests {
    @Test func choosingWhisperSwitchesThePackageAndShowsTheLanguage() async throws {
        let rig = try DictationSettingsModelTests.Rig()
        defer { rig.harness.tearDown() }
        let settings = DictationSettings(rig.harness.context.settings)
        let model = DictationSettingsModel(
            package: ModelCatalog.parakeetUltra, manager: rig.fixture.manager(), settings: settings,
            authorizer: rig.authorizer, listDevices: { [] }, pickFolder: { nil }, openURL: { _ in })
        #expect(!model.usesPinnedLanguage)
        #expect(model.packages.map(\.id) == ["parakeet-ultra", "whisper-large-v3-turbo"])

        var signals = 0
        model.onStatusChange = { signals += 1 }
        model.selectSpeechModel("whisper-large-v3-turbo")
        #expect(model.package.id == "whisper-large-v3-turbo")
        // The Ready banner names the model, so the shell reads it again even when the place is unchanged.
        #expect(signals >= 1)
        #expect(model.usesPinnedLanguage)
        #expect(settings.speechModelID == "whisper-large-v3-turbo")

        model.speechLanguage = "en"
        #expect(settings.speechLanguage == "en")

        // An unknown id changes nothing.
        let before = signals
        model.selectSpeechModel("nope")
        #expect(model.package.id == "whisper-large-v3-turbo")
        #expect(signals == before)
    }
}
