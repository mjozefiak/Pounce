import FluidAudio
import Foundation
import Testing

@testable import LintelSpeech

@Suite struct DiarizationCatalogTests {
    private let package = ModelCatalog.diarizationCommunity1

    @Test func theEntryIsPinnedAndCarriesTheLicense() {
        #expect(package.id == "diarization-community-1")
        #expect(package.license == "CC-BY-4.0")
        #expect(package.attribution.contains("CC BY 4.0"))
        #expect(package.attribution.contains("pyannote"))
        #expect(package.attribution.contains("FluidInference"))
        for source in package.sources {
            #expect(source.revision.count == 40)
            #expect(source.revision.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(source.repository == "FluidInference/speaker-diarization-coreml")
        }
    }

    @Test func everyFileHasASha256AndASize() {
        #expect(!package.files.isEmpty)
        for entry in package.files {
            #expect(entry.file.sha256.count == 64, "\(entry.file.path)")
            #expect(entry.file.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(entry.file.path)")
            #expect(entry.file.size > 0)
        }
        #expect(Set(package.files.map(\.file.path)).count == package.files.count)
        #expect(package.totalBytes < 30_000_000)
    }

    @Test func downloadsGoToTheAllowedHostOnly() throws {
        for entry in package.files {
            let url = try #require(entry.source.url(for: entry.file))
            #expect(url.scheme == "https")
            #expect(ModelCatalog.isAllowedDownloadHost(try #require(url.host)))
            #expect(url.host == "huggingface.co")
            #expect(url.path.contains("/resolve/7eab74f3463c736418d0eb10296261ae581146c9/"))
        }
    }

    @Test func theFilesAreExactlyWhatTheDiarizerOpens() {
        let paths = Set(package.files.map { package.relativePath(of: $0.file, in: $0.source) })
        for name in ModelCatalog.diarizationModelNames {
            #expect(paths.contains(name + "/weights/weight.bin"), "\(name)")
            #expect(paths.contains(name + "/coremldata.bin"), "\(name)")
            #expect(paths.contains(name + "/model.mil"), "\(name)")
        }
        #expect(paths.contains(ModelCatalog.diarizationParametersFile))
        // FluidAudio's own list of required files agrees with the catalog.
        let required = ModelNames.OfflineDiarizer.requiredModels
        for name in required {
            #expect(paths.contains(name) || paths.contains { $0.hasPrefix(name + "/") }, "\(name)")
        }
    }

    @Test func theSpeechModelListDoesNotOfferIt() {
        #expect(!ModelCatalog.all.contains { $0.id == package.id })
        #expect(ModelCatalog.package(id: package.id) == nil)
        #expect(ModelCatalog.diarizationPackage(id: package.id) == package)
        #expect(ModelCatalog.diarizationPackage(id: "nope") == nil)
    }
}

@Suite struct PCM16SampleSourceTests {
    @Test func fluidAudioReadsPCM16SamplesAtAnyOffset() throws {
        let source = PCM16SampleSource(samples: [0, 16_384, -16_384, 32_767])
        #expect(source.sampleCount == 4)
        var out = [Float](repeating: 9, count: 3)
        try out.withUnsafeMutableBufferPointer { try source.copySamples(into: $0.baseAddress!, offset: 1, count: 3) }
        #expect(out == [0.5, -0.5, Float(32_767) / 32_768])
        // Past the end nothing is written.
        var rest = [Float](repeating: 9, count: 2)
        try rest.withUnsafeMutableBufferPointer { try source.copySamples(into: $0.baseAddress!, offset: 3, count: 2) }
        #expect(rest[1] == 9)
    }
}
