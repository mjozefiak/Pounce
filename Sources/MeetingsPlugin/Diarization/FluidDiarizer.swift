import CoreML
import FluidAudio
import Foundation
import PounceSpeech

/// Offline speaker diarization through FluidAudio (pyannote Community-1 in Core ML).
///
/// **Models load only from the folder `ModelManager` owns.** `OfflineDiarizerModels.load(from:)` and
/// `OfflineDiarizerManager.prepareModels()` go through FluidAudio's `ModelHub`, which downloads whatever it
/// finds missing or not matching its own revision marker and, after a failed load, deletes the cache and
/// downloads again. Pounce's folder has no such marker, so those paths are never used: the four compiled
/// models and `plda-parameters.json` are opened here with `MLModel(contentsOf:)` and handed to the public
/// `OfflineDiarizerModels` initializer. A missing file is an error (`modelsUnavailable`), never a fetch.
actor FluidDiarizer: Diarizer {
    nonisolated let modelID: String
    private let modelFolder: URL
    private var manager: OfflineDiarizerManager?
    private let makeManager: @Sendable (URL) throws -> OfflineDiarizerManager

    /// - Parameter makeManager: builds the manager from the model folder; tests replace it with a fake.
    init(
        modelFolder: URL, modelID: String = "diarization-community-1",
        makeManager: @escaping @Sendable (URL) throws -> OfflineDiarizerManager = FluidDiarizer.loadManager(from:)
    ) {
        self.modelFolder = modelFolder
        self.modelID = modelID
        self.makeManager = makeManager
    }

    var isLoaded: Bool { manager != nil }

    func diarize(_ source: any AudioSampleSource, maximumSamples: Int) async throws -> [DiarizedSpan] {
        let buffer = try await DiarizationAudioBuffer.readOffTheCaller(from: source, maximumSamples: maximumSamples)
        guard !buffer.samples.isEmpty else { return [] }
        try Task.checkCancellation()
        // The manager is a non-Sendable class that only this actor holds and that runs one request at a time
        // (the actor is not re-entered by a second `diarize` before this one returns its result).
        nonisolated(unsafe) let manager = try loadedManager()
        let result: DiarizationResult
        do {
            result = try await manager.process(
                audioSource: PCM16SampleSource(samples: buffer.samples), audioLoadingSeconds: 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DiarizationError.failed
        }
        try Task.checkCancellation()
        return result.segments.map {
            DiarizedSpan(
                cluster: $0.speakerId, startMs: Int(($0.startTimeSeconds * 1_000).rounded()),
                endMs: Int(($0.endTimeSeconds * 1_000).rounded()))
        }
    }

    func release() {
        manager = nil
    }

    /// Loads the manager when it is not loaded yet (also what `diarize` does first).
    func loadIfNeeded() throws {
        _ = try loadedManager()
    }

    private func loadedManager() throws -> OfflineDiarizerManager {
        if let manager { return manager }
        let created = try makeManager(modelFolder)
        manager = created
        return created
    }

    @Sendable static func loadManager(from folder: URL) throws -> OfflineDiarizerManager {
        let models = try loadModels(from: folder)
        let created = OfflineDiarizerManager(config: .default)
        created.initialize(models: models)
        return created
    }

    /// Opens the models from `folder` without touching the network. Throws `modelsUnavailable` when a file is
    /// missing or cannot be opened.
    static func loadModels(from folder: URL) throws -> OfflineDiarizerModels {
        let fileManager = FileManager.default
        let parameters = folder.appending(path: Names.parameters)
        for name in Names.models + [Names.parameters]
        where !fileManager.fileExists(atPath: folder.appending(path: name).path) {
            throw DiarizationError.modelsUnavailable
        }
        let started = Date()
        do {
            func open(_ name: String, units: MLComputeUnits) throws -> MLModel {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = units
                // As FluidAudio's ModelHub sets it for every model it loads.
                configuration.allowLowPrecisionAccumulationOnGPU = true
                return try MLModel(contentsOf: folder.appending(path: name), configuration: configuration)
            }
            // The same compute units FluidAudio uses: FBank on the CPU, the rest wherever Core ML decides.
            return OfflineDiarizerModels(
                segmentationModel: try open(Names.models[0], units: .all),
                fbankModel: try open(Names.models[1], units: .cpuOnly),
                embeddingModel: try open(Names.models[2], units: .all),
                pldaRhoModel: try open(Names.models[3], units: .all),
                pldaPsi: try psi(in: parameters),
                compilationDuration: Date().timeIntervalSince(started))
        } catch {
            throw DiarizationError.modelsUnavailable
        }
    }

    enum Names {
        /// Segmentation, FBank, Embedding, PldaRho: the order `loadModels` opens them in.
        static let models = ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc"]
        static let parameters = "plda-parameters.json"
    }

    /// `tensors.psi` of `plda-parameters.json`: little-endian `Float32`, base64 (the layout FluidAudio reads).
    static func psi(in file: URL) throws -> [Double] {
        let data = try Data(contentsOf: file)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tensors = root["tensors"] as? [String: Any], let psi = tensors["psi"] as? [String: Any],
            let base64 = psi["data_base64"] as? String,
            let decoded = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
            decoded.count >= MemoryLayout<Float>.size
        else { throw DiarizationError.modelsUnavailable }
        var floats = [Float](repeating: 0, count: decoded.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { decoded.copyBytes(to: $0) }
        return floats.map(Double.init)
    }
}
