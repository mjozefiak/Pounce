import Foundation
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

/// Counts every request that reaches a registered `URLProtocol`: any use of `URLSession` (also `.shared`)
/// during a test shows up here. The protocol fails the request, so nothing leaves the machine either way.
final class NetworkTripwire: URLProtocol {
    static let hits = Mutex(0)
    static var count: Int { hits.withLock { $0 } }
    static func reset() { hits.withLock { $0 = 0 } }

    override class func canInit(with request: URLRequest) -> Bool {
        hits.withLock { $0 += 1 }
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

/// An `AudioSampleSource` that serves a number of constant chunks and counts how many were read.
final class CountingSource: AudioSampleSource {
    private let chunks: Mutex<(remaining: Int, read: Int)>
    private let chunkSamples: Int
    let sampleRate = 16_000
    var endState: AudioEndState? { chunks.withLock { $0.remaining == 0 ? .complete : nil } }
    var chunksRead: Int { chunks.withLock { $0.read } }

    init(chunks: Int, chunkSamples: Int, value: Float = 0.25) {
        self.chunks = Mutex((chunks, 0))
        self.chunkSamples = chunkSamples
        self.value = value
    }

    private let value: Float

    func nextChunk() throws -> [Float]? {
        let go = chunks.withLock { state -> Bool in
            guard state.remaining > 0 else { return false }
            state.remaining -= 1
            state.read += 1
            return true
        }
        return go ? [Float](repeating: value, count: chunkSamples) : nil
    }
}

@Suite(.serialized) struct DiarizerTests {
    // MARK: Budget

    @Test func theBufferReadsEverythingWithinTheBudgetAsInt16() throws {
        let source = CountingSource(chunks: 4, chunkSamples: 1_000, value: 0.5)
        let buffer = try DiarizationAudioBuffer.read(from: source, maximumSamples: 4_000)
        #expect(buffer.samples.count == 4_000)
        #expect(buffer.samples.allSatisfy { $0 == 16_384 })
        #expect(buffer.durationMs == 250)
    }

    @Test func theBufferStopsReadingAsSoonAsTheBudgetIsExceeded() {
        let source = CountingSource(chunks: 100, chunkSamples: 1_000)
        #expect(throws: DiarizationError.overBudget(maximumSamples: 2_500)) {
            _ = try DiarizationAudioBuffer.read(from: source, maximumSamples: 2_500)
        }
        // Chunks 1 and 2 fit, the third is read and refused; nothing more is decrypted.
        #expect(source.chunksRead == 3)
    }

    @Test func clippingNeverTrapsOnOutOfRangeSamples() throws {
        let loud = CountingSource(chunks: 1, chunkSamples: 4, value: 3)
        #expect(
            try DiarizationAudioBuffer.read(from: loud, maximumSamples: 4).samples == [32_767, 32_767, 32_767, 32_767])
        let quiet = CountingSource(chunks: 1, chunkSamples: 2, value: -3)
        #expect(try DiarizationAudioBuffer.read(from: quiet, maximumSamples: 2).samples == [-32_768, -32_768])
    }

    @Test func theDefaultBudgetIsTheUnmeasuredNinetyMinuteCap() {
        #expect(DiarizationBudget.unmeasuredMaximumDuration == .seconds(90 * 60))
        #expect(DiarizationBudget().maximumSamplesPerTrack == 90 * 60 * 16_000)
        #expect(DiarizationBudget(maximumSamplesPerTrack: -5).maximumSamplesPerTrack == 0)
    }

    @Test func aCancelledTaskStopsTheReadBetweenChunks() async {
        let source = CountingSource(chunks: 1_000, chunkSamples: 100)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DiarizationAudioBuffer.readOffTheCaller(from: source, maximumSamples: 1_000_000)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(source.chunksRead <= 1)
    }

    // MARK: Models load from the folder only

    @Test func anEmptyOrIncompleteFolderIsAnErrorAndNeverANetworkRequest() async throws {
        URLProtocol.registerClass(NetworkTripwire.self)
        defer { URLProtocol.unregisterClass(NetworkTripwire.self) }
        NetworkTripwire.reset()
        let directory = try TemporaryDirectory()
        // Empty folder.
        #expect(throws: DiarizationError.modelsUnavailable) { _ = try FluidDiarizer.loadModels(from: directory.url) }
        // Every file present but not a model: Core ML refuses it, and still nothing is fetched or deleted.
        for name in FluidDiarizer.Names.models {
            try FileManager.default.createDirectory(
                at: directory.url.appending(path: name), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: directory.url.appending(path: name + "/coremldata.bin"))
        }
        try Data("{}".utf8).write(to: directory.url.appending(path: FluidDiarizer.Names.parameters))
        #expect(throws: DiarizationError.modelsUnavailable) { _ = try FluidDiarizer.loadModels(from: directory.url) }
        for name in FluidDiarizer.Names.models {
            #expect(FileManager.default.fileExists(atPath: directory.url.appending(path: name).path))
        }

        let diarizer = FluidDiarizer(modelFolder: directory.url)
        let source = CountingSource(chunks: 2, chunkSamples: 16_000)
        await #expect(throws: DiarizationError.modelsUnavailable) {
            _ = try await diarizer.diarize(source, maximumSamples: 100_000)
        }
        #expect(await !diarizer.isLoaded)
        await diarizer.release()
        #expect(NetworkTripwire.count == 0)
    }

    @Test func aTrackOverTheBudgetFailsBeforeAnyModelIsLoaded() async throws {
        let directory = try TemporaryDirectory()
        let diarizer = FluidDiarizer(modelFolder: directory.url)
        await #expect(throws: DiarizationError.overBudget(maximumSamples: 10)) {
            _ = try await diarizer.diarize(CountingSource(chunks: 1, chunkSamples: 100), maximumSamples: 10)
        }
        #expect(await !diarizer.isLoaded)
    }

    @Test func psiIsReadFromTheParametersFile() throws {
        let directory = try TemporaryDirectory()
        let floats: [Float] = [1.5, -2, 0.25]
        let data = floats.withUnsafeBytes { Data($0) }
        let json = "{\"tensors\":{\"psi\":{\"data_base64\":\"\(data.base64EncodedString())\"}}}"
        let file = directory.url.appending(path: "plda-parameters.json")
        try Data(json.utf8).write(to: file)
        #expect(try FluidDiarizer.psi(in: file) == [1.5, -2, 0.25])
        try Data("{\"tensors\":{}}".utf8).write(to: file)
        #expect(throws: DiarizationError.modelsUnavailable) { _ = try FluidDiarizer.psi(in: file) }
    }

    /// The download paths of FluidAudio (`OfflineDiarizerModels.load`, `prepareModels`, `ModelHub`, `DownloadUtils`)
    /// would fetch and delete files by themselves; no source file of the plugin may name them. Comments and
    /// string literals are stripped first, so a guard comment that names a forbidden call does not count and a
    /// call that merely follows a comment on the same line does. (A source scan is a tripwire, not a proof: the
    /// `NetworkTripwire` test above is the behavioural guarantee.)
    @Test func noPluginSourceUsesAFluidAudioDownloadPath() throws {
        let files = TestPaths.meetingsSourceFiles()
        #expect(!files.isEmpty)
        let forbidden = [
            "prepareModels", "OfflineDiarizerModels.load", "ModelHub", "DownloadUtils", "downloadAndLoad",
            "URLSession",
        ]
        for file in files {
            let code = Self.strippingCommentsAndStrings(try String(contentsOf: file, encoding: .utf8))
            for word in forbidden {
                #expect(!code.contains(word), "\(file.lastPathComponent) uses \(word)")
            }
        }
        #expect(Self.strippingCommentsAndStrings("a // URLSession\nb \"URLSession\" /* x */ c") == "a \nb \"\"  c")
        #expect(Self.strippingCommentsAndStrings("URLSession.shared // tail").contains("URLSession"))
    }

    static func strippingCommentsAndStrings(_ source: String) -> String {
        var out = ""
        let chars = Array(source)
        var index = 0
        func hasPrefix(_ text: String, at i: Int) -> Bool {
            let t = Array(text)
            return i + t.count <= chars.count && Array(chars[i..<(i + t.count)]) == t
        }
        while index < chars.count {
            if hasPrefix("//", at: index) {
                while index < chars.count, chars[index] != "\n" { index += 1 }
            } else if hasPrefix("/*", at: index) {
                index += 2
                while index < chars.count, !hasPrefix("*/", at: index) { index += 1 }
                index += 2
            } else if hasPrefix("\"\"\"", at: index) {
                index += 3
                while index < chars.count, !hasPrefix("\"\"\"", at: index) { index += 1 }
                index += 3
                out += "\"\""
            } else if chars[index] == "\"" {
                index += 1
                while index < chars.count, chars[index] != "\"", chars[index] != "\n" {
                    index += chars[index] == "\\" ? 2 : 1
                }
                index += 1
                out += "\"\""
            } else {
                out.append(chars[index])
                index += 1
            }
        }
        return out
    }

    // MARK: Release

    @Test func aCancelledDiarizeThrowsCancellationAndLoadsNothing() async {
        let diarizer = FluidDiarizer(modelFolder: URL(filePath: "/nonexistent"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await diarizer.diarize(CountingSource(chunks: 3, chunkSamples: 1_000), maximumSamples: 100_000)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await !diarizer.isLoaded)
    }
}

@Suite struct DiarizationCatalogLinkTests {
    @Test func theCatalogListsExactlyTheFilesTheDiarizerOpens() {
        #expect(ModelCatalog.diarizationModelNames == FluidDiarizer.Names.models)
        #expect(ModelCatalog.diarizationParametersFile == FluidDiarizer.Names.parameters)
    }
}
