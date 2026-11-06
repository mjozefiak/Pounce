import CryptoKit
import Foundation
import LintelKit
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

/// A download that writes the package's bytes at once: no network, no URLSession.
final class InstantDownloader: FileDownloading {
    let data: [String: Data]
    let calls = Mutex(0)

    init(data: [String: Data]) { self.data = data }

    var callCount: Int { calls.withLock { $0 } }

    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int) -> Void) async throws {
        calls.withLock { $0 += 1 }
        guard let bytes = data[url.lastPathComponent] else { throw ModelError.httpStatus(404) }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        progress(bytes.count)
    }
}

/// A one-file package on a made-up repository, with a manager over a temporary folder and the fake downloader.
struct ModelRig {
    let directory: TemporaryDirectory
    let package: ModelPackage
    let downloader: InstantDownloader
    let manager: ModelManager
    let bytes = Data("model bytes".utf8)

    init(id: String = "rig-model") throws {
        directory = try TemporaryDirectory()
        let bytes = bytes
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        package = ModelPackage(
            id: id, title: "Rig model", license: "MIT", attribution: "Made up for tests",
            sources: [
                ModelSource(
                    repository: "test/rig", revision: "rev", into: "",
                    files: [ModelFile(path: "weights.bin", size: bytes.count, sha256: digest)])
            ])
        downloader = InstantDownloader(data: ["weights.bin": bytes])
        manager = ModelManager(
            directory: directory.url.appending(path: "Models", directoryHint: .isDirectory),
            downloader: downloader, availableSpace: { _ in .max })
    }

    /// A folder with the package's files, as a user would download it by hand.
    func makeUserFolder(complete: Bool = true) throws -> URL {
        let folder = directory.url.appending(path: "mine", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if complete { try bytes.write(to: folder.appending(path: "weights.bin")) }
        return folder
    }
}

final class FakeAuthorizer: MicrophoneAuthorizer {
    init(_ initial: MicrophoneAccess = .notDetermined) { state.withLock { $0.access = initial } }

    private struct State {
        var access = MicrophoneAccess.notDetermined
        var requests = 0
        var grants = true
        var gate: Latch?
        var answers = 0
    }

    private let state = Mutex(State())

    var requests: Int { state.withLock { $0.requests } }
    func deny() { state.withLock { $0.grants = false } }
    /// The next `requestAccess()` waits for this latch (the permission prompt is on screen).
    func holdAnswers(until gate: Latch) { state.withLock { $0.gate = gate } }
    var answers: Int { state.withLock { $0.answers } }

    func status() -> MicrophoneAccess { state.withLock { $0.access } }

    func requestAccess() async -> Bool {
        let gate = state.withLock { state -> Latch? in
            state.requests += 1
            return state.gate
        }
        await gate?.wait()
        return state.withLock { state in
            state.access = state.grants ? .granted : .denied
            state.answers += 1
            return state.grants
        }
    }
}

/// Everything the settings model needs, wired to fakes and temporary folders.
@MainActor
final class SettingsRig {
    let harness: MeetingsHarness
    let models: ModelRig
    let diarizationModels: ModelRig
    let authorizer: FakeAuthorizer
    let backend = FakeBackend()
    let tone = FakeTonePlayer()
    let busy = Shared(false)
    let library: MeetingsLibrary
    let spool: SpoolStorage
    let model: MeetingsSettingsModel
    let picked = Shared<URL?>(nil)
    let changes = Shared(0)
    let activity = MeetingActivity()
    let notesService: NotesService
    let llmModels: ModelRig
    /// Opens when a folder check starts, so a test knows the card is verifying without polling.
    let verificationStarted = Latch()
    /// When set, a folder check waits for it to open: the check stays "in flight" until the test lets it end.
    let verificationRelease: Latch?

    init(
        settings: [String: SettingValue] = [:], access: MicrophoneAccess = .notDetermined,
        holdVerification: Bool = false,
        openURL: @escaping @MainActor (URL) -> Void = { _ in }
    ) throws {
        harness = try MeetingsHarness(settings: settings)
        verificationRelease = holdVerification ? Latch() : nil
        models = try ModelRig(id: "rig-speech")
        diarizationModels = try ModelRig(id: "rig-diarization")
        authorizer = FakeAuthorizer(access)
        library = harness.library()
        spool = SpoolStorage(pluginDirectory: harness.pluginDirectory)
        llmModels = try ModelRig(id: "rig-llm")
        notesService = NotesService(
            NotesService.Dependencies(
                library: library, settings: harness.meetingsSettings, lease: LLMLease(), modelFile: { _ in nil }))
        let busy = busy
        let usage = MeetingsModelUsage { _ in busy.get() }
        let meetingsSettings = harness.meetingsSettings
        let picked = picked
        let speech = MeetingsModelCardModel(
            package: models.package, manager: models.manager, usage: usage,
            customFolder: { meetingsSettings.speechModelFolder },
            setCustomFolder: { meetingsSettings.setSpeechModelFolder($0) }, pickFolder: { picked.get() },
            verifyFolder: { [verificationStarted, verificationRelease, manager = models.manager] folder, package in
                verificationStarted.open()
                await verificationRelease?.wait()
                try await manager.verify(folder: folder, for: package)
            })
        let diarization = MeetingsModelCardModel(
            package: diarizationModels.package, manager: diarizationModels.manager, usage: usage,
            customFolder: { meetingsSettings.diarizationModelFolder },
            setCustomFolder: { meetingsSettings.setDiarizationModelFolder($0) },
            pickFolder: { picked.get() })
        let backend = backend
        let tone = tone
        let changes = changes
        model = MeetingsSettingsModel(
            settings: meetingsSettings, library: library,
            privacy: MeetingsPrivacyActions(
                library: library, spool: spool, activity: activity, changed: { changes.update { $0 += 1 } }),
            speech: speech, diarization: diarization,
            systemAudioTest: SystemAudioTestModel(makeTest: {
                SystemAudioSelfTest(backend: backend, player: tone, settle: .zero, sleeper: { _ in })
            }),
            notes: NotesSettingsModel(
                settings: meetingsSettings, service: notesService, manager: llmModels.manager, lease: LLMLease()),
            speechPackages: [models.package], authorizer: authorizer,
            listDevices: { [.init(uid: "usb-1", name: "USB mic")] }, openURL: openURL)
    }

    func setBusy(_ value: Bool) { busy.update { $0 = value } }
    func pick(_ url: URL?) { picked.update { $0 = url } }

    /// Writes a spool folder with a file in it, as a recording would.
    func makeSpool(_ uuid: String) throws {
        let directory = try spool.prepare(meeting: #require(UUID(uuidString: uuid)))
        try Data("audio".utf8).write(to: directory.appending(path: "mic.spool"))
    }

    func spoolExists(_ uuid: String) -> Bool {
        UUID(uuidString: uuid).map { FileManager.default.fileExists(atPath: spool.directory(for: $0).path) } ?? false
    }
}

enum Sample {
    static let ids = [
        "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002",
        "00000000-0000-4000-8000-000000000003", "00000000-0000-4000-8000-000000000004",
        "00000000-0000-4000-8000-000000000005",
    ]
}

/// A value shared with `@Sendable` closures.
final class Shared<Value: Sendable>: Sendable {
    private let state: Mutex<Value>
    init(_ value: Value) { state = Mutex(value) }
    func get() -> Value { state.withLock { $0 } }
    func update(_ change: (inout Value) -> Void) { state.withLock { change(&$0) } }
}
