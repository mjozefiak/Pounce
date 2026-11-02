import Foundation
import Testing

@testable import DictationPlugin

@Suite struct RepetitionFilterTests {
    @Test func aLoopedPhraseIsCutDownToItsFirstOccurrence() {
        #expect(
            RepetitionFilter.clean("Thank you. Thank you. Thank you. Thank you. Thank you.") == "Thank you.")
        #expect(RepetitionFilter.clean("to jest to jest to jest to jest dobre") == "to jest dobre")
        #expect(
            RepetitionFilter.clean("Zapisz to w pliku. a b c a b c a b c a b c a b c koniec")
                == "Zapisz to w pliku. a b c koniec"
        )
    }

    @Test func aWordNeedsFiveRepeatsAndAPhraseThree() {
        #expect(RepetitionFilter.clean("no no no no no no") == "no")
        #expect(RepetitionFilter.clean("no no no no") == "no no no no")
        #expect(RepetitionFilter.clean("tak, tak, tak") == "tak, tak, tak")
        #expect(RepetitionFilter.clean("very good very good") == "very good very good")
        #expect(RepetitionFilter.clean("very good very good very good") == "very good")
    }

    @Test func caseAndPunctuationDoNotHideALoop() {
        #expect(RepetitionFilter.clean("Okay. okay, OKAY okay! Okay okay") == "Okay.")
    }

    @Test func ordinaryTextIsLeftAlone() {
        let text = "Napisz funkcję, która sortuje listę, a potem ją odwraca, a potem zwraca wynik."
        #expect(RepetitionFilter.clean(text) == text)
        #expect(RepetitionFilter.clean("") == "")
        #expect(RepetitionFilter.clean("   ") == "")
    }

    @Test func aLoopInTheMiddleKeepsTheRestInOrder() {
        #expect(
            RepetitionFilter.clean("Hello there. Thanks for watching. Thanks for watching. Thanks for watching. Bye.")
                == "Hello there. Thanks for watching. Bye.")
    }
}

@Suite struct SwitchingEngineTests {
    @Test func loadsTheChosenEngineAndUnloadsTheOtherWhenTheChoiceChanges() async throws {
        let first = FakeEngine()
        let second = FakeEngine()
        let choice = ChoiceBox("a")
        let engine = SwitchingEngine(engines: ["a": first, "b": second], selected: { choice.value })
        #expect(await !engine.isLoaded)

        try await engine.load(modelFolder: URL(filePath: "/tmp/none"))
        #expect(await engine.isLoaded)
        #expect(try await engine.transcribe([0.1]).text.hasPrefix("segment"))
        #expect(first.state.withLock { $0.calls } == 1)

        choice.value = "b"
        // The loaded engine is the old one: not loaded for the new choice.
        #expect(await !engine.isLoaded)
        try await engine.load(modelFolder: URL(filePath: "/tmp/none"))
        #expect(first.state.withLock { $0.unloads } == 1)
        #expect(second.isLoaded)
        _ = try await engine.transcribe([0.1])
        #expect(second.state.withLock { $0.calls } == 1)

        await engine.unload()
        #expect(await !engine.isLoaded)
        #expect(second.state.withLock { $0.unloads } == 1)
    }

    @Test func anUnknownChoiceFailsInsteadOfLoadingSomethingElse() async {
        let engine = SwitchingEngine(engines: ["a": FakeEngine()], selected: { "zzz" })
        await #expect(throws: SwitchingEngine.SwitchingError.self) {
            try await engine.load(modelFolder: URL(filePath: "/tmp/none"))
        }
    }
}

final class ChoiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String
    init(_ value: String) { stored = value }
    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite struct WhisperCatalogTests {
    @Test func theWhisperPackageHoldsEverythingWhisperKitNeedsAndNothingItWouldDownload() {
        let package = ModelCatalog.whisperLargeV3Turbo
        let paths = Set(package.files.map { package.relativePath(of: $0.file, in: $0.source) })
        for required in [
            "AudioEncoder.mlmodelc/weights/weight.bin", "TextDecoder.mlmodelc/model.mil",
            "MelSpectrogram.mlmodelc/coremldata.bin", "TextDecoderContextPrefill.mlmodelc/weights/weight.bin",
            "config.json", "tokenizer.json", "tokenizer_config.json",
            "vad/silero-vad-unified-256ms-v6.2.1.mlmodelc/weights/weight.bin",
        ] {
            #expect(paths.contains(required), "\(required)")
        }
        // The repository's per-model folder is stripped from the local paths.
        #expect(!paths.contains { $0.hasPrefix("openai_whisper") })
        #expect(paths.count == package.files.count)
        #expect(package.totalBytes > 640_000_000 && package.totalBytes < 660_000_000)
        #expect(package.license == "MIT")
        for entry in package.files {
            #expect(entry.file.sha256.count == 64)
            #expect(entry.source.url(for: entry.file)?.host == "huggingface.co")
        }
    }

    @Test func theDownloadURLKeepsTheRepositoryPathAndTheLocalPathDropsIt() throws {
        let package = ModelCatalog.whisperLargeV3Turbo
        let entry = try #require(package.files.first { $0.file.path.hasSuffix("AudioEncoder.mlmodelc/model.mil") })
        #expect(
            entry.source.url(for: entry.file)?.path
                == "/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/model.mil"
        )
        #expect(package.relativePath(of: entry.file, in: entry.source) == "AudioEncoder.mlmodelc/model.mil")
    }

    @Test func bothPackagesCarryTheSameVADModel() {
        for package in ModelCatalog.all {
            let paths = package.files.map { package.relativePath(of: $0.file, in: $0.source) }
            #expect(paths.contains(ModelCatalog.sileroVADPath + "/weights/weight.bin"), "\(package.id)")
        }
        #expect(ModelCatalog.all.map(\.id) == ["parakeet-ultra", "whisper-large-v3-turbo"])
        #expect(ModelCatalog.package(id: "nope") == nil)
    }
}

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

        model.selectSpeechModel("whisper-large-v3-turbo")
        #expect(model.package.id == "whisper-large-v3-turbo")
        #expect(model.usesPinnedLanguage)
        #expect(settings.speechModelID == "whisper-large-v3-turbo")

        model.speechLanguage = "en"
        #expect(settings.speechLanguage == "en")

        // An unknown id changes nothing.
        model.selectSpeechModel("nope")
        #expect(model.package.id == "whisper-large-v3-turbo")
    }
}
