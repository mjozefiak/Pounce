import Foundation
import LintelProviders
import Observation

/// What the "Notes are written by" section of Settings → Meetings shows and does (mockup v2 of the notes-model
/// choice, owner decisions D5–D15 of 2026-11-20): the provider menu (Local first, then the providers this build
/// knows), the model menu of the chosen one, its status, "Try it", and the notice that goes with an external
/// provider. Choosing a provider IS the consent (no window); a change of the model asks nothing.
///
/// Processes: the model starts a process only through `probe` and `tryOut`, and only while a provider is chosen
/// (`refreshStatus` does nothing for Local). Neither carries meeting content. `ProviderRunner.run` (the only
/// path with a transcript) is not reachable from here.
@MainActor @Observable
final class ProviderChoiceModel {
    /// A row of the provider menu.
    enum Entry: Equatable, Identifiable {
        case local
        case provider(ProviderID)

        var id: String {
            switch self {
            case .local: "local"
            case .provider(let id): id.rawValue
            }
        }
    }

    /// What the last availability check of the chosen provider found (nothing until it ran).
    enum Check: Equatable {
        case unknown
        case checking
        case known(ProviderStatus)
    }

    enum TestState: Equatable {
        case idle
        case running
        case worked
        case failed(ProviderJobFailure.Reason)
        case unavailable
    }

    /// The choice as stored; `nil` is Local. Re-read by `reload()`.
    private(set) var selection: NotesProviderSelection?
    private(set) var check = Check.unknown
    private(set) var testState = TestState.idle
    /// The CLI's version number from the last check, for the Status row.
    private(set) var version: String?
    /// "Details" of the notice, expanded in place (no window).
    var detailsExpanded = false
    /// D12: "Use Local" pressed while a job runs; the pane asks once.
    private(set) var confirmingUseLocal = false
    /// The last provider job that wrote nothing, and whether a job is running now (copied from the board).
    private(set) var failure: ProviderJobFailure?
    private(set) var jobRunning = false

    let descriptors: [ProviderDescriptor]

    @ObservationIgnored private let settings: MeetingsSettings
    @ObservationIgnored private let service: NotesService
    @ObservationIgnored private let probe: @MainActor @Sendable (ProviderDescriptor) async -> ProviderStatusReport
    @ObservationIgnored private let tryOutRun: @MainActor @Sendable (ProviderID, String) async -> TryOutResult
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let copyText: @MainActor (String) -> Void
    @ObservationIgnored private let chooseFile: @MainActor () -> URL?
    /// `PluginContext.openModels`: "Write on This Mac" without the built-in model leads to its download.
    @ObservationIgnored private let changed: @Sendable () -> Void
    var earlierMark: EarlierMark?
    @ObservationIgnored private let lastMarked: @MainActor () -> EarlierMark?
    @ObservationIgnored private var lastProbe: Date?
    @ObservationIgnored private let now: @MainActor () -> Date
    static let probeInterval: TimeInterval = 600
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var tryTask: Task<Void, Never>?

    init(
        settings: MeetingsSettings, service: NotesService,
        descriptors: [ProviderDescriptor] = MeetingsSettings.knownProviders,
        probe: @escaping @MainActor @Sendable (ProviderDescriptor) async -> ProviderStatusReport,
        tryOut: @escaping @MainActor @Sendable (ProviderID, String) async -> TryOutResult,
        openURL: @escaping @MainActor (URL) -> Void, copyText: @escaping @MainActor (String) -> Void,
        chooseFile: @escaping @MainActor () -> URL?, changed: @escaping @Sendable () -> Void,
        now: @escaping @MainActor () -> Date = { Date() },
        lastMarked: @escaping @MainActor () -> EarlierMark? = { nil }
    ) {
        self.lastMarked = lastMarked
        self.now = now
        self.settings = settings
        self.service = service
        self.descriptors = descriptors
        self.probe = probe
        tryOutRun = tryOut
        self.openURL = openURL
        self.copyText = copyText
        self.chooseFile = chooseFile
        self.changed = changed
        selection = settings.notesProviderSelection
    }

    // MARK: What is chosen

    var entries: [Entry] { [.local] + descriptors.map { .provider($0.id) } }

    var isLocal: Bool { selection == nil }

    /// The section, its notice and the banner are shown whenever notes are written automatically OR a provider is
    /// chosen: "Regenerate" and "Try Again" send to the provider even with automatic notes off, so the notice and
    /// "Use Local" must be reachable then.
    static func surfacesProvider(notesEnabled: Bool, isLocal: Bool) -> Bool { notesEnabled || !isLocal }

    /// The descriptor of the chosen provider, `nil` for Local.
    var chosen: ProviderDescriptor? {
        guard let selection else { return nil }
        return descriptors.first { $0.id == selection.provider }
    }

    /// The models of the chosen provider, as offered in the second menu.
    var models: [ProviderModel] { chosen?.models ?? [] }

    /// The chosen model; a stored id the catalog does not list (a hidden or typed one) shows as it is.
    var model: ProviderModel? {
        guard let selection, let chosen else { return nil }
        return chosen.models.first { $0.id == selection.model }
            ?? ProviderModel(id: selection.model, displayName: selection.model)
    }

    /// Opus and Fable use more of the subscription limit and take longer: the note under the menu.
    var showsHeavierNote: Bool { model?.heavier ?? false }

    /// The latest meeting whose notes a provider wrote: after "Use Local" its mark stays (mockup state 7).
    struct EarlierMark: Equatable {
        var title: String
        var chip: String
        var provider: String
    }

    func reload() {
        selection = settings.notesProviderSelection
        earlierMark = selection == nil ? lastMarked() : nil
        if selection == nil, settings.qaProviderScenario == "earlier" {
            earlierMark = EarlierMark(
                title: "Orchard weekly sync", chip: "Sent to: Claude · Sonnet", provider: "Claude Code")
        }
        let snapshot = service.board.snapshot
        failure = snapshot.providerFailure
        jobRunning = snapshot.jobRunning
        applyQAScenario()
        if selection == nil {
            check = .unknown
            testState = .idle
            confirmingUseLocal = false
        }
    }

    /// DEBUG QA only: the scenario name (`nil` in a release build).
    var qaScenario: String? { settings.qaProviderScenario }

    /// DEBUG QA only: shows a state no test run can reach without a real CLI (`plugins.meetings.qaProviderScenario`).
    private func applyQAScenario() {
        guard selection != nil, let scenario = settings.qaProviderScenario else { return }
        switch scenario {
        case "running": jobRunning = true
        case "confirm":
            jobRunning = true
            confirmingUseLocal = true
        case "details": detailsExpanded = true
        default:
            if let reason = ProviderJobFailure.Reason(rawValue: scenario) {
                failure = ProviderJobFailure(
                    reason: reason, meetingID: 0, title: "Orchard weekly sync",
                    startedAt: Date(timeIntervalSince1970: 1_730_642_700))
            }
        }
    }

    /// The board changed (a job started, ended or failed).
    func boardChanged() {
        let snapshot = service.board.snapshot
        let before = (failure, jobRunning)
        failure = snapshot.providerFailure
        jobRunning = snapshot.jobRunning
        if !jobRunning { confirmingUseLocal = false }
        if before.0 != failure || before.1 != jobRunning { changed() }
    }

    // MARK: Choosing

    /// The shell asks for the new state of the banner and the pane after every change.
    private func didChange() {
        reload()
        Task { await service.refreshAvailability() }
        changed()
    }

    /// Choosing a provider is the consent (no window); the notice is shown with the choice. Nothing is sent
    /// until the next notes job; the status check that follows carries no meeting content.
    func choose(_ id: ProviderID) {
        guard let descriptor = descriptors.first(where: { $0.id == id }) else { return }
        if selection?.provider == id { return }
        // A model remembered for this provider is not kept across a switch: the default one starts.
        settings.setNotesProvider(NotesProviderSelection(provider: id, model: descriptor.defaultModelID))
        service.board.update { $0.providerFailure = nil }
        check = .unknown
        testState = .idle
        detailsExpanded = false
        didChange()
        refreshStatus()
    }

    /// "Use Local": back to the built-in model. While a job runs (D12=B) it first asks, because what was already
    /// sent stays with the provider.
    func useLocal() {
        guard selection != nil else { return }
        if service.board.snapshot.jobRunning, !confirmingUseLocal {
            confirmingUseLocal = true
            changed()
            return
        }
        confirmUseLocal()
    }

    func confirmUseLocal() {
        confirmingUseLocal = false
        settings.clearNotesProvider()
        service.board.update { $0.providerFailure = nil }
        checkTask?.cancel()
        tryTask?.cancel()
        service.selectionChanged()
        didChange()
    }

    func cancelUseLocal() {
        confirmingUseLocal = false
        changed()
    }

    /// A different model of the same provider: no question. A job that already runs is stopped (SIGTERM) and the
    /// meeting is written again once with the new model; its result is dropped (spec: notes are never put
    /// together from two models; the transcript goes out a second time).
    func chooseModel(_ id: String) {
        guard let selection, selection.model != id, models.contains(where: { $0.id == id }) else { return }
        settings.setNotesProvider(NotesProviderSelection(provider: selection.provider, model: id))
        service.selectionChanged()
        testState = .idle
        didChange()
    }

    // MARK: Status

    /// Looks whether the CLI is installed, signed in and of a known version. Only while a provider is chosen; no
    /// content. DEBUG only: `plugins.meetings.qaProviderStatus` replaces the process.
    func refreshStatus(force: Bool = true) {
        guard let chosen else { return }
        // The app becoming active again is not a reason to start two processes each time: a working CLI is looked
        // at again after `probeInterval` (a problem is looked at every time, so a fix shows at once).
        if !force, status == .ready, let last = lastProbe, now().timeIntervalSince(last) < Self.probeInterval {
            return
        }
        lastProbe = now()
        if let forced = settings.qaProviderStatus {
            check = .known(forced)
            version = forced == .ready ? "2.1.329" : nil
            changed()
            return
        }
        checkTask?.cancel()
        check = .checking
        let probe = probe
        checkTask = Task { [weak self] in
            let report = await probe(chosen)
            let status = report.status
            guard !Task.isCancelled, let self, self.chosen?.id == chosen.id else { return }
            self.version = report.version
            self.check = .known(status)
            // The CLI works now: a failure that was only about the CLI is over.
            if status == .ready, let reason = self.failure?.reason,
                [.notInstalled, .notSignedIn, .incompatibleVersion].contains(reason)
            {
                self.clearFailure()
            }
            self.changed()
        }
    }

    /// The status once a check finished; `nil` while it is unknown or running.
    var status: ProviderStatus? {
        if case .known(let status) = check { return status }
        return nil
    }

    // MARK: Try it

    /// "Test": a short fixed text of ours (not a meeting) goes to the chosen provider. Needs a chosen provider.
    func testProvider() {
        guard let selection, testState != .running else { return }
        testState = .running
        let run = tryOutRun
        tryTask = Task { [weak self] in
            let result = await run(selection.provider, selection.model)
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .worked: self.testState = .worked
            case .unavailable: self.testState = .unavailable
            case .failed(let failure):
                self.testState = .failed(ProviderChoiceModel.reason(of: failure))
            }
        }
    }

    static func reason(of failure: ProviderFailure) -> ProviderJobFailure.Reason {
        switch failure {
        case .incompatibleVersion: .incompatibleVersion
        case .rateLimited: .rateLimited
        case .modelNotAvailable: .modelNotAvailable
        case .notSignedIn: .notSignedIn
        case .network: .network
        case .other: .other
        }
    }

    // MARK: Actions of the banners and rows

    /// "Choose Model" of the banner: the pane opens the model menu when this turns on.
    var modelMenuRequested = false

    /// The closures of the banner's buttons (`ProviderStatusBanner`); each runs on the main actor.
    var bannerActions: ProviderBannerActions {
        ProviderBannerActions(
            useLocal: { [weak self] in self?.useLocal() },
            install: { [weak self] in self?.openInstallPage() },
            chooseFile: { [weak self] in self?.chooseBinary() },
            checkAgain: { [weak self] in self?.checkAgain() },
            update: { [weak self] in self?.openInstallPage() },
            updateLintel: { [weak self] in self?.openReleasesPage() },
            chooseModel: { [weak self] in self?.modelMenuRequested = true },
            writeOnThisMac: { [weak self] in self?.writeOnThisMac() },
            retry: { [weak self] in self?.retry() })
    }

    static let releasesURL = URL(string: "https://github.com/mjozefiak/lintel/releases")

    func openReleasesPage() {
        if let url = Self.releasesURL { openURL(url) }
    }

    static let installURL = URL(string: "https://code.claude.com/docs/en/setup")
    static let loginCommand = "claude auth login"

    func openInstallPage() {
        if let url = Self.installURL { openURL(url) }
    }

    func copyLoginCommand() { copyText(Self.loginCommand) }

    /// "Choose File…": the CLI at a place the fixed search does not look. Checked by `ProviderLocator` before use.
    func chooseBinary() {
        guard let url = chooseFile() else { return }
        settings.setNotesProviderBinary(url.path)
        refreshStatus()
    }

    /// "Check Again" and "Try Again" of the status rows.
    func checkAgain() { refreshStatus() }

    /// "Try Again": the notes of that meeting are written again (the transcript goes again).
    func retry() {
        guard let failure else { return }
        service.regenerate(failure.meetingID)
    }

    /// D7=C: "Write on This Mac": the built-in model writes this meeting's notes once, nothing more is sent.
    func writeOnThisMac() {
        guard let failure else { return }
        service.writeOnThisMac(failure.meetingID)
    }

    func clearFailure() {
        service.board.update { $0.providerFailure = nil }
        reload()
        changed()
    }
}

/// Carries "the board changed" from `NotesService`'s `changed` closure (any thread) to the model on the main actor.
final class ProviderBoardRelay: @unchecked Sendable {
    @MainActor weak var target: ProviderChoiceModel?

    func notify() {
        Task { @MainActor [weak self] in self?.target?.boardChanged() }
    }
}
