import Foundation
import PounceKit
import PounceSpeech
import os

/// Runs one dictation from the shortcut to the pasted text: the gesture, the microphone permission, the
/// model check, the session, Escape, the HUD and the paste (spec: Proposed Solution). Everything it touches
/// comes in through the initializer, so the whole flow runs in tests with fakes.
@MainActor
final class DictationController {
    struct Dependencies {
        var authorizer: any MicrophoneAuthorizer
        var models: ModelManager
        var package: () -> ModelPackage
        var customFolder: () -> URL?
        /// Builds the recording for the model folder to load from.
        var makeSession: (URL, @escaping @Sendable (DictationSession.Event) -> Void) -> DictationSession
        var lease: SpeechEngineLease
        var paster: TextPaster
        var hud: any HUDPresenter
        var claimEscape: (@escaping @MainActor @Sendable () -> Void) -> EscapeKeyClaim
        var openSettings: () -> Void
        var clock: any Clock<Duration>
        var now: () -> ContinuousClock.Instant = { ContinuousClock.now }
        /// Saves a finished dictation in the history (a no-op when it is off or unavailable).
        var recordHistory: @MainActor (DictationEntry) -> Void = { _ in }
        /// The bundle id of the app in front, read just before pasting.
        var frontmostBundleID: () -> String? = { nil }
        var formatMode: () -> FormatMode = { .raw }
        var speechModelID: () -> String = { "" }
        var formatterModel: () -> String? = { nil }
        var wallClock: () -> Date = { Date() }
    }

    private let deps: Dependencies
    private var gesture: RecordingGesture
    private var session: DictationSession?
    private var escapeClaim: EscapeKeyClaim?
    private var finishTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "app.pounce", category: "dictation")

    /// The raw transcript of the last dictation (before any formatting), kept in memory only, for "paste the
    /// raw version of the last dictation".
    private(set) var lastRawText: String?

    init(_ dependencies: Dependencies) {
        deps = dependencies
        gesture = RecordingGesture(now: dependencies.now)
    }

    var isBusy: Bool { gesture.state != .idle }

    // MARK: Input

    /// A phase of the shortcut.
    func keyEvent(_ phase: KeyPhase) {
        apply(gesture.handle(phase == .down ? .keyDown : .keyUp))
    }

    /// The menu item: starts a toggle recording, or ends the running one.
    func menu() {
        apply(gesture.handle(.menu))
    }

    /// Escape or the HUD's ✕.
    func cancel() {
        apply(gesture.handle(.cancel))
    }

    private func apply(_ action: RecordingGesture.Action) {
        switch action {
        case .none: break
        case .start: begin()
        case .finish: finish()
        case .cancel: abort()
        }
    }

    // MARK: Start

    private func begin() {
        finishTask = Task { [weak self] in await self?.prepareAndStart() }
    }

    private func prepareAndStart() async {
        switch deps.authorizer.status() {
        case .granted: break
        case .denied:
            return fail(.microphoneDenied)
        case .notDetermined:
            // The key press is the user's action: the prompt is allowed now.
            deps.hud.show(.allowMicrophone)
            guard await deps.authorizer.requestAccess() else { return fail(.microphoneDenied) }
        }
        guard gesture.isRecording else { return deps.hud.hide() }

        let package = deps.package()
        let location = await deps.models.location(of: package, customFolder: deps.customFolder())
        guard let folder = location.folder else {
            switch location {
            case .customFolderUnavailable: return fail(.modelUnavailable)
            default: return fail(.modelMissing)
            }
        }
        // The user may have cancelled or released the key while the checks ran.
        guard gesture.isRecording else { return deps.hud.hide() }

        let claim = deps.claimEscape { [weak self] in self?.cancel() }
        escapeClaim = claim
        let session = deps.makeSession(folder) { [weak self] event in
            Task { @MainActor in self?.sessionEvent(event) }
        }
        self.session = session
        var recording = HUDState.Recording()
        recording.escapeCancels = claim.isActive
        recordingState = recording
        deps.hud.show(.recording(recording))
        do {
            try await session.start()
        } catch {
            logger.error("Recording could not start: \(String(describing: error), privacy: .public)")
            fail(.noMicrophone)
        }
    }

    private var recordingState = HUDState.Recording()

    private func sessionEvent(_ event: DictationSession.Event) {
        guard session != nil, gesture.isRecording else { return }
        switch event {
        case .level(let level):
            recordingState.level = level
        case .loadingModel:
            recordingState.loadingModel = true
        case .modelLoaded:
            recordingState.loadingModel = false
        case .limitApproaching(let seconds):
            recordingState.secondsLeft = seconds
        case .loadFailed(let busy):
            // No point in recording for a model that will not come: tell the user now.
            let session = session
            releaseEscape()
            end(with: busy ? .speechModelBusy : .modelFailedToLoad)
            Task { await session?.cancel() }
            return
        case .limitReached, .audioLost:
            // What was said so far is still finished and pasted.
            menu()
            return
        }
        deps.hud.show(.recording(recordingState))
    }

    // MARK: Finish

    private func finish() {
        let previous = finishTask
        finishTask = Task { [weak self] in
            await previous?.value
            await self?.produceAndPaste()
        }
    }

    private func produceAndPaste() async {
        guard let session else {
            gesture.finished()
            return
        }
        releaseEscape()
        deps.hud.show(.finishing)
        do {
            let output = try await session.finish()
            logger.info(
                "Dictated \(output.segmentCount, privacy: .public) segments, \(output.duration, privacy: .public) s")
            lastRawText = output.rawText
            let target = deps.frontmostBundleID()
            let outcome = await deps.paster.paste(output.text)
            self.session = nil
            recordHistory(output, outcome: outcome, target: target)
            switch outcome {
            case .pasted:
                if output.formatting.isPartial {
                    deps.hud.show(
                        .pastedUnformatted(all: output.formatting.fellBack == output.formatting.chunks))
                } else {
                    deps.hud.show(.pasted)
                }
            case .copied(let reason): deps.hud.show(.copied(reason))
            }
            gesture.finished()
        } catch DictationSession.Failure.silence {
            end(with: .nothingHeard)
        } catch DictationSession.Failure.cancelled {
            self.session = nil
            gesture.finished()
        } catch DictationSession.Failure.busy {
            end(with: .speechModelBusy)
        } catch {
            end(with: .modelFailedToLoad)
        }
    }

    /// Saves the dictation after it was pasted (or copied), with what became of it.
    private func recordHistory(_ output: DictationSession.Output, outcome: TextPaster.Outcome, target: String?) {
        let mode = deps.formatMode()
        let summary = output.formatting
        let status: FormatStatus
        if mode == .raw || summary.chunks == 0 {
            status = .none
        } else if summary.fellBack == 0 {
            status = .ok
        } else if summary.fellBack == summary.chunks {
            status = .failed
        } else {
            status = .partial
        }
        let raw = output.rawText
        let languages: String
        switch Language.dominant(in: raw) {
        case .polish: languages = "pl"
        case .english: languages = "en"
        case .unknown: languages = ""
        }
        let pasted: Bool
        if case .pasted = outcome { pasted = true } else { pasted = false }
        deps.recordHistory(
            DictationEntry(
                createdAt: deps.wallClock(), durationMs: Int(output.duration * 1000), rawText: raw,
                formattedText: mode == .clean && status != .failed && status != .none ? output.text : nil,
                formatMode: mode, formatStatus: status, detectedLanguages: languages,
                speechModelID: deps.speechModelID(), formatterModel: mode == .clean ? deps.formatterModel() : nil,
                targetBundleID: pasted ? target : nil, pasteResult: pasted ? .pasted : .copied))
    }

    /// Pastes text from the history into the app in front (the panel has just closed).
    func pasteFromHistory(_ text: String) async {
        guard !isBusy else { return }
        try? await deps.clock.sleep(for: .milliseconds(200))
        switch await deps.paster.paste(text) {
        case .pasted: deps.hud.show(.pasted)
        case .copied(let reason): deps.hud.show(.copied(reason))
        }
    }

    // MARK: Raw version

    /// "Paste the raw version of the last dictation": the transcript before formatting, into the app in front.
    func pasteLastRaw() {
        guard !isBusy, let text = lastRawText else {
            if !isBusy { deps.hud.show(.problem(.nothingToPaste)) }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await deps.paster.paste(text) {
            case .pasted: deps.hud.show(.pasted)
            case .copied(let reason): deps.hud.show(.copied(reason))
            }
        }
    }

    // MARK: Cancel and errors

    private func abort() {
        let session = session
        self.session = nil
        finishTask?.cancel()
        finishTask = nil
        releaseEscape()
        deps.hud.hide()
        Task { await session?.cancel() }
    }

    private func fail(_ problem: HUDState.Problem) {
        releaseEscape()
        deps.hud.show(.problem(problem))
        if let session {
            self.session = nil
            Task { await session.cancel() }
        }
        gesture.finished()
    }

    private func end(with problem: HUDState.Problem) {
        session = nil
        deps.hud.show(.problem(problem))
        gesture.finished()
    }

    private func releaseEscape() {
        escapeClaim?.release()
        escapeClaim = nil
    }

    /// The plugin is being switched off: drop everything.
    func shutDown() async {
        finishTask?.cancel()
        releaseEscape()
        deps.hud.hide()
        await session?.cancel()
        session = nil
        await deps.lease.evictIdle()
    }
}
