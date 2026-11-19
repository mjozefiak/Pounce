import Foundation
import Testing

@testable import DictationPlugin
@testable import LintelCore
@testable import LintelSpeech

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "vocab-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct VocabularyStoreTests {
    private let sample = [
        VocabularyStore.Term(term: "AuthService", aliases: ["auth service"]),
        VocabularyStore.Term(term: "Łódź", aliases: ["lodz"]),
    ]

    @Test func savesAndReadsBackThroughAFileWithMode0600() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(directory: directory)
        try store.save(sample)
        #expect(store.replacer.apply(to: "otwórz auth service") == "otwórz AuthService")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        let reopened = VocabularyStore(directory: directory)
        reopened.load()
        #expect(reopened.terms == sample)
        #expect(reopened.replacer.apply(to: "jadę do lodz") == "jadę do Łódź")
    }

    @Test func aMissingFileIsAnEmptyVocabulary() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(directory: directory)
        store.load()
        #expect(store.terms.isEmpty)
        #expect(store.replacer.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test(arguments: ["not json", "{}", "{\"version\": 1}", "{\"version\": 0, \"terms\": []}", "[]"])
    func aCorruptFileIsSetAsideOnceAndTheVocabularyStartsEmpty(contents: String) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(directory: directory)
        try Data(contents.utf8).write(to: store.fileURL)
        store.load()
        #expect(store.terms.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        let corrupt = directory.appending(path: VocabularyStore.corruptFileName)
        #expect(try String(contentsOf: corrupt, encoding: .utf8) == contents)

        // A second corrupt file replaces the copy: there is only ever one.
        try Data("other".utf8).write(to: store.fileURL)
        store.load()
        #expect(try String(contentsOf: corrupt, encoding: .utf8) == "other")
        try store.save(sample)
        #expect(store.terms == sample)
    }

    @Test func aNewerFileIsReadButNeverWrittenOrMoved() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(directory: directory)
        let newer = #"{"version": 2, "terms": [{"term": "Kafka", "aliases": ["kafka"], "extra": true}]}"#
        try Data(newer.utf8).write(to: store.fileURL)
        store.load()
        #expect(store.isReadOnly)
        #expect(store.terms.map(\.term) == ["Kafka"])
        #expect(throws: VocabularyStore.SaveError.readOnly) { try store.save(sample) }
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == newer)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "vocabulary.json.corrupt").path))
    }

    @Test func aNewerFileWithAnUnknownShapeIsKeptAndSimplyEmpty() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(directory: directory)
        let newer = #"{"version": 3, "words": {"a": 1}}"#
        try Data(newer.utf8).write(to: store.fileURL)
        store.load()
        #expect(store.isReadOnly)
        #expect(store.terms.isEmpty)
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == newer)
    }

    @Test func eraseRemovesTheFileAndTheCorruptCopy() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(directory: directory)
        try store.save(sample)
        try Data("x".utf8).write(to: directory.appending(path: VocabularyStore.corruptFileName))
        try store.erase()
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "vocabulary.json.corrupt").path))
        #expect(store.replacer.isEmpty)
        try store.erase()  // nothing left: still fine
    }

    @Test func tooManyTermsAreRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(directory: directory)
        let many = (0...VocabularyStore.maximumTerms).map { VocabularyStore.Term(term: "t\($0)", aliases: []) }
        #expect(throws: VocabularyStore.SaveError.tooManyTerms) { try store.save(many) }
    }
}

@Suite struct VocabularySessionTests {
    /// Makes the formatted text differ from the raw one.
    private struct UppercasingFormatter: TextFormatter {
        func format(chunk: String, previousContext: String?) async throws -> FormatResult {
            FormatResult(text: chunk.replacingOccurrences(of: "segment", with: "Segment") + ".", outcome: .formatted)
        }
    }

    private func run(formatter: (any TextFormatter)?, replace: @escaping @Sendable (String) -> String) async throws
        -> DictationSession.Output
    {
        let second = AudioFormat.sampleRate
        let session = DictationSession(
            audio: ScriptedAudioInput(seconds: 3), vad: RangeVAD([second..<(2 * second)]), engine: FakeEngine(),
            formatter: formatter, replaceTerms: replace, modelFolder: URL(filePath: "/tmp/none"))
        try await session.start()
        return try await session.finish()
    }

    private let replacer = TermReplacer(entries: [.init(term: "Seg-One", aliases: ["segment 1"])])

    @Test func rawModeAppliesTheVocabularyButKeepsTheRawTranscript() async throws {
        let replacer = replacer
        let output = try await run(formatter: nil) { replacer.apply(to: $0) }
        #expect(output.text == "Seg-One")
        #expect(output.rawText == "segment 1")
    }

    @Test func formattedModeReplacesAfterTheFormatter() async throws {
        let replacer = replacer
        let output = try await run(formatter: UppercasingFormatter()) { replacer.apply(to: $0) }
        #expect(output.text == "Seg-One.")
        #expect(output.rawText == "segment 1")
    }

    @Test func withoutAVocabularyTheResultIsUnchanged() async throws {
        let plain = try await run(formatter: nil) { $0 }
        let empty = try await run(formatter: nil) { TermReplacer(entries: []).apply(to: $0) }
        #expect(plain.text == "segment 1")
        #expect(empty == plain)
    }
}

@MainActor
@Suite struct VocabularyPluginTests {
    private let sample = [VocabularyStore.Term(term: "AuthService", aliases: ["auth service"])]

    private func replacement(
        _ harness: DictationHarness, terms: [VocabularyStore.Term]
    ) throws -> @Sendable (String) -> String {
        let store = VocabularyStore(directory: harness.context.storageDirectory)
        try store.save(terms)
        return DictationPlugin.termReplacement(settings: DictationSettings(harness.context.settings), vocabulary: store)
    }

    @Test func theVocabularyIsAppliedByDefault() throws {
        let harness = try DictationHarness()
        defer { harness.tearDown() }
        let replace = try replacement(harness, terms: sample)
        #expect(replace("open auth service") == "open AuthService")
    }

    @Test func switchedOffTheTextIsUnchangedWhateverTheVocabulary() throws {
        let harness = try DictationHarness(settings: ["plugins.dictation.vocabularyEnabled": .bool(false)])
        defer { harness.tearDown() }
        let replace = try replacement(harness, terms: sample)
        #expect(replace("open auth service") == "open auth service")
    }

    @Test func anEmptyVocabularyLeavesTheTextUnchanged() throws {
        let harness = try DictationHarness()
        defer { harness.tearDown() }
        let replace = try replacement(harness, terms: [])
        #expect(replace("open auth service") == "open auth service")
    }

    @Test func eraseDataRemovesTheVocabularyAndItsCorruptCopy() async throws {
        let harness = try DictationHarness()
        defer { harness.tearDown() }
        let plugin = DictationPlugin(context: harness.context)
        try plugin.vocabulary.save(sample)
        let corrupt = harness.context.storageDirectory.appending(path: VocabularyStore.corruptFileName)
        try Data("x".utf8).write(to: corrupt)
        #expect(FileManager.default.fileExists(atPath: plugin.vocabulary.fileURL.path))
        try await plugin.eraseData()
        #expect(!FileManager.default.fileExists(atPath: plugin.vocabulary.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
        #expect(plugin.vocabulary.replacer.isEmpty)
    }
}
