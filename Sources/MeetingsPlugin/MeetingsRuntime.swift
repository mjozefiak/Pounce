import Foundation
import LintelKit
import LintelSpeech
import os

/// The real parts behind the controller and the library: the speech engine, the voice activity detector, the
/// audio sources, the sleep assertion and the finalizer (diarization). Nothing here runs in a test: tests give
/// the controller and the library fakes instead (spec: Architecture, "Wyjątek od ...").
///
/// Audio sources are created per session by `makeMicrophone` and `makeSystemAudio`; they are the only places
/// that reach AVAudioEngine and Core Audio.
struct MeetingsRuntime: Sendable {
    let settings: MeetingsSettings
    let speechManager: ModelManager
    let diarizationManager: ModelManager
    /// At most one recording at a time, shared by everything that can start one.
    let gate = MeetingSessionGate()
    let logger: Logger
    var makeMicrophone: @Sendable (String?) -> any AudioInput = { MicrophoneCapture(deviceUID: $0) }
    var makeSystemAudio: @Sendable () -> any AudioInput = { SystemAudioSource(backend: CoreAudioProcessTapBackend()) }

    @MainActor
    init(context: PluginContext, settings: MeetingsSettings) {
        self.settings = settings
        logger = context.logger
        speechManager = ModelManagers.shared.manager(
            for: context.modelsDirectory.appending(path: MeetingsUI.speechDirectoryName, directoryHint: .isDirectory),
            logger: context.logger)
        diarizationManager = ModelManagers.shared.manager(
            for: context.modelsDirectory.appending(
                path: MeetingsUI.diarizationDirectoryName, directoryHint: .isDirectory),
            logger: context.logger)
    }

    // MARK: Models

    var speechPackage: ModelPackage {
        ModelCatalog.package(id: settings.speechModelID) ?? ModelCatalog.parakeetUltra
    }

    /// Where the speech model chosen in Settings is.
    func speechLookup() async -> SpeechModelLookup {
        let package = speechPackage
        let location = await speechManager.location(of: package, customFolder: settings.speechModelFolder)
        if let folder = location.folder { return .ready(modelID: package.id, folder: folder) }
        if case .customFolderUnavailable = location { return .unavailable }
        return .missing
    }

    /// One engine per recording, fixed to the model the recording started with: a change in Settings during
    /// the meeting applies to the next one.
    func makeEngine(modelID: String) -> any SpeechEngine {
        let settings = settings
        return SwitchingEngine(
            engines: [
                ModelCatalog.parakeetUltra.id: ParakeetEngine(),
                ModelCatalog.whisperLargeV3Turbo.id: WhisperKitEngine(language: { settings.speechLanguage }),
            ],
            selected: { modelID })
    }

    // MARK: Session

    func makeFinalizer(store: MeetingsStore, keys: MeetingKeys, spool: SpoolStorage) -> MeetingFinalizer {
        let settings = settings
        let manager = diarizationManager
        return MeetingFinalizer(
            store: store, keys: keys, spool: spool, isEnabled: { settings.diarization },
            modelFolder: {
                await manager.location(
                    of: ModelCatalog.diarizationCommunity1, customFolder: settings.diarizationModelFolder
                ).folder
            }, logger: logger)
    }

    func makeSession(_ request: MeetingSessionRequest) -> MeetingSession {
        let finalizer = makeFinalizer(store: request.store, keys: request.keys, spool: request.spool)
        let vadFolder = request.modelFolder.appending(path: ModelCatalog.sileroVADPath)
        // A recording of the system audio only gets a microphone that never starts: the session carries on
        // with the other track.
        let microphone: any AudioInput =
            request.recordsMicrophone ? makeMicrophone(settings.inputDevice) : UnavailableAudioInput()
        return MeetingSession(
            store: request.store, keys: request.keys, spool: request.spool, mic: microphone,
            system: request.recordsSystemAudio ? makeSystemAudio() : nil,
            makeVAD: { LazyVAD(modelFolder: vadFolder) }, engine: makeEngine(modelID: request.modelID),
            modelID: request.modelID, modelFolder: request.modelFolder, sleepAssertion: IOKitSleepAssertion(),
            gate: gate, beforeReady: finalizer.hook, sourceBundleID: request.sourceBundleID, logger: logger)
    }

    // MARK: Recovery and "Dokończ"

    /// The resumer the library uses after a crash and for "Dokończ": the same speech setup and finalizer.
    func makeResumer(store: MeetingsStore, keys: MeetingKeys, spool: SpoolStorage) -> any MeetingResuming {
        let finalizer = makeFinalizer(store: store, keys: keys, spool: spool)
        let runtime = self
        return MeetingResumer(
            store: store, keys: keys, spool: spool,
            makeVAD: { FolderResolvingVAD(folder: { await runtime.speechLookup().folder }) },
            speech: {
                guard case .ready(let id, let folder) = await runtime.speechLookup() else { return nil }
                return ResumeSpeech(engine: runtime.makeEngine(modelID: id), modelID: id, folder: folder)
            }, finalize: finalizer.hook, logger: logger)
    }
}

extension SpeechModelLookup {
    var folder: URL? {
        if case .ready(_, let folder) = self { return folder }
        return nil
    }
}

/// An input that never starts. The session treats it as a microphone that could not be opened.
struct UnavailableAudioInput: AudioInput {
    struct Unavailable: Error {}

    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws -> AsyncStream<[Float]> {
        throw Unavailable()
    }

    func stop() async {}
}

/// Silero detection for the resumer, which needs the detector before it knows the model folder: the folder is
/// looked up when the first audio arrives.
actor FolderResolvingVAD: VoiceActivityDetector {
    struct ModelMissing: Error {}

    private let folder: @Sendable () async -> URL?
    private var detector: SileroVAD?

    init(folder: @escaping @Sendable () async -> URL?) {
        self.folder = folder
    }

    func process(_ samples: [Float]) async throws -> [VADEvent] {
        if detector == nil {
            guard let folder = await folder() else { throw ModelMissing() }
            detector = try SileroVAD(modelFolder: folder.appending(path: ModelCatalog.sileroVADPath))
        }
        return try await detector?.process(samples) ?? []
    }
}
