import AppKit
import Foundation
import Observation
import PounceSpeech
import os

/// What the Dictation pane and the setup step show and do: the speech model (download, folder, remove), the
/// microphone and its permission. Shared by both screens.
@MainActor @Observable
final class DictationSettingsModel {
    private(set) var location = ModelLocation.missing
    private(set) var progress: ModelProgress?
    private(set) var errorMessage: String?
    private(set) var isVerifying = false
    private(set) var microphone = MicrophoneAccess.notDetermined
    private(set) var devices: [MicrophoneCapture.InputDevice] = []
    private(set) var level: Float?
    var inputDevice: String? {
        didSet { settings.setInputDevice(inputDevice) }
    }
    var restoresClipboard: Bool {
        didSet { settings.setRestoresClipboard(restoresClipboard) }
    }

    /// The package of the engine chosen in Settings.
    private(set) var package: ModelPackage
    /// The speech models to choose from.
    let packages: [ModelPackage]
    @ObservationIgnored private let manager: ModelManager
    @ObservationIgnored private let settings: DictationSettings
    @ObservationIgnored private let authorizer: any MicrophoneAuthorizer
    @ObservationIgnored private let listDevices: () -> [MicrophoneCapture.InputDevice]
    @ObservationIgnored private let pickFolder: @MainActor () -> URL?
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let makeCapture: (String?) -> any AudioInput
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var testTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "app.pounce", category: "dictation")

    init(
        package: ModelPackage, packages: [ModelPackage]? = nil, manager: ModelManager, settings: DictationSettings,
        authorizer: any MicrophoneAuthorizer,
        listDevices: @escaping () -> [MicrophoneCapture.InputDevice] = MicrophoneCapture.inputDevices,
        pickFolder: @escaping @MainActor () -> URL?, openURL: @escaping @MainActor (URL) -> Void,
        makeCapture: @escaping (String?) -> any AudioInput = { MicrophoneCapture(deviceUID: $0) }
    ) {
        self.packages = packages ?? ModelCatalog.all
        self.package = package
        self.manager = manager
        self.settings = settings
        self.authorizer = authorizer
        self.listDevices = listDevices
        self.pickFolder = pickFolder
        self.openURL = openURL
        self.makeCapture = makeCapture
        inputDevice = settings.inputDevice
        restoresClipboard = settings.restoresClipboard
    }

    /// The Whisper engine needs a pinned language; the Parakeet engine detects it.
    var usesPinnedLanguage: Bool { package.id == ModelCatalog.whisperLargeV3Turbo.id }

    var speechLanguage: String {
        get { settings.speechLanguage }
        set {
            settings.setSpeechLanguage(newValue)
        }
    }

    /// The speech model's id as chosen in Settings; choosing another one shows that model's own status.
    var speechModelID: String { package.id }

    func selectSpeechModel(_ id: String) {
        guard id != package.id, let chosen = packages.first(where: { $0.id == id }) else { return }
        cancelDownload()
        package = chosen
        settings.setSpeechModelID(id)
        errorMessage = nil
        Task { await refresh() }
    }

    var isDownloading: Bool { progress != nil }
    var isInstalled: Bool { location.folder != nil }

    /// Re-reads the model's place, the microphone and the device list (the pane calls it when it appears).
    func refresh() async {
        location = await manager.location(of: package, customFolder: settings.speechModelFolder)
        microphone = authorizer.status()
        devices = listDevices()
    }

    // MARK: Model

    func download() {
        guard downloadTask == nil else { return }
        errorMessage = nil
        progress = ModelProgress(bytesDone: 0, bytesTotal: package.totalBytes)
        let package = package
        let manager = manager
        downloadTask = Task { [weak self] in
            do {
                try await manager.install(package) { value in
                    Task { @MainActor in self?.progress = value }
                }
                self?.settings.setSpeechModelFolder(nil)
            } catch is CancellationError {
            } catch {
                self?.errorMessage = Self.message(for: error)
            }
            self?.progress = nil
            self?.downloadTask = nil
            await self?.refresh()
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// "Choose folder…": checks the files and sums of a model the user downloaded by hand.
    func chooseFolder() {
        guard let folder = pickFolder() else { return }
        errorMessage = nil
        isVerifying = true
        Task {
            do {
                try await manager.verify(folder: folder, for: package)
                settings.setSpeechModelFolder(folder)
            } catch {
                errorMessage = Self.message(for: error)
            }
            isVerifying = false
            await refresh()
        }
    }

    /// Goes back to the downloaded model.
    func useDownloadedModel() {
        settings.setSpeechModelFolder(nil)
        Task { await refresh() }
    }

    func removeModel() {
        Task {
            do {
                try await manager.delete(package)
                errorMessage = nil
            } catch {
                errorMessage = Self.message(for: error)
            }
            await refresh()
        }
    }

    static func message(for error: Error) -> String {
        guard let error = error as? ModelError else {
            return String(
                localized: "The download did not finish. Check the connection and try again.",
                comment: "Dictation settings error after a failed download")
        }
        switch error {
        case .insufficientSpace(let needed, _):
            let size = ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file)
            return String(
                localized: "Not enough free space. The model needs \(size).",
                comment: "Dictation settings error when the disk is too full")
        case .checksumMismatch, .sizeMismatch:
            return String(
                localized: "A file does not match the expected checksum, so it was not used.",
                comment: "Dictation settings error after a failed checksum")
        case .disallowedHost, .httpStatus:
            return String(
                localized: "The download was refused by the server. Try again later.",
                comment: "Dictation settings error after the download server answered with an error")
        case .folderIncomplete(let missing):
            return String(
                localized: "This folder is missing \(missing.count) of the model's files.",
                comment: "Dictation settings error when a chosen model folder is incomplete")
        case .notInstalled:
            return String(localized: "The model is not installed.", comment: "Dictation settings error")
        }
    }

    // MARK: Microphone

    /// "Allow": the user's click, so the system prompt may appear.
    func requestMicrophone() {
        Task {
            _ = await authorizer.requestAccess()
            microphone = authorizer.status()
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            openURL(url)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            openURL(url)
        }
    }

    /// "Test": shows the input level for a few seconds. Nothing is kept.
    func testMicrophone() {
        guard testTask == nil, microphone == .granted else { return }
        let capture = makeCapture(inputDevice)
        testTask = Task { [weak self] in
            do {
                let stream = try await capture.start { value in
                    Task { @MainActor in self?.level = value }
                }
                try? await Task.sleep(for: .seconds(4))
                await capture.stop()
                for await _ in stream {}
            } catch {
                self?.errorMessage = String(
                    localized: "No microphone found", comment: "Dictation HUD when there is no input device")
            }
            self?.level = nil
            self?.testTask = nil
        }
    }
}
