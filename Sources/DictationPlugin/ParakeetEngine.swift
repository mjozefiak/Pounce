import CoreML
import FluidAudio
import Foundation

/// Parakeet Ultra through FluidAudio. Loads only from the folder `ModelManager` gives it (`loadLocal` never
/// touches the network), and keeps the model in memory until `unload()`.
actor ParakeetEngine: SpeechEngine {
    enum EngineError: Error {
        case notLoaded
    }

    private var manager: AsrManager?

    var isLoaded: Bool { manager != nil }

    func load(modelFolder: URL) async throws {
        let models = try AsrModels.loadLocal(from: modelFolder, version: .ultra)
        manager = AsrManager(config: .default, models: models)
    }

    func transcribe(_ samples: [Float]) async throws -> TranscriptSegment {
        guard let manager else { throw EngineError.notLoaded }
        // The model needs a minimum of audio; very short utterances are padded with silence.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: AudioFormat.sampleRate)
        let padded =
            samples.count >= minimum ? samples : samples + [Float](repeating: 0, count: minimum - samples.count)
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(padded, decoderState: &state)
        return TranscriptSegment(text: result.text)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}

/// Silero voice activity detection through FluidAudio, fed in the 4096-sample (256 ms) chunks its model takes.
actor SileroVAD: VoiceActivityDetector {
    private let manager: VadManager
    private var state: VadStreamState
    private var pending: [Float] = []
    private let segmentation = VadSegmentationConfig.default

    /// - Parameter modelFolder: the `.mlmodelc` folder of the Silero model inside the model package.
    init(modelFolder: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: modelFolder, configuration: configuration)
        let manager = VadManager(config: .default, vadModel: model)
        self.manager = manager
        self.state = VadStreamState.initial()
    }

    func process(_ samples: [Float]) async throws -> [VADEvent] {
        pending.append(contentsOf: samples)
        var events: [VADEvent] = []
        while pending.count >= VadManager.chunkSize {
            let chunk = Array(pending.prefix(VadManager.chunkSize))
            pending.removeFirst(VadManager.chunkSize)
            let result = try await manager.processStreamingChunk(chunk, state: state, config: segmentation)
            state = result.state
            if let event = result.event {
                events.append(VADEvent(kind: event.isStart ? .speechStart : .speechEnd, sampleIndex: event.sampleIndex))
            }
        }
        return events
    }
}
