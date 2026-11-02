import Foundation
import Observation

/// What the "Formatting" section of the Dictation pane shows and does: the mode, the servers found on this Mac,
/// the model to use, and a "Try it" button. Nothing here leaves the Mac: every address goes through
/// `LoopbackPolicy`.
@MainActor @Observable
final class FormattingSettingsModel {
    enum TryState: Equatable {
        case idle
        case running
        case result(original: String, text: String, cleaned: Bool)
    }

    /// The text "Try it" cleans up.
    static let sample = "yyy no więc jutro mamy spotkanie o dziesiątej nie to znaczy o jedenastej w biurze"

    var mode: DictationSettings.Mode {
        didSet {
            settings.setMode(mode)
            if mode == .cleanup { Task { await refresh() } }
        }
    }
    private(set) var endpoints: [LLMEndpoint] = []
    private(set) var isProbing = false
    private(set) var tryState = TryState.idle
    /// The address field's text; `addressError` is set while it is not a loopback address.
    var address: String {
        didSet { applyAddress() }
    }
    private(set) var addressError = false
    private(set) var selectedEndpoint: URL?
    private(set) var selectedModel: String?

    @ObservationIgnored private let settings: DictationSettings
    @ObservationIgnored private let probe: EndpointProbe
    @ObservationIgnored private let formatter: LocalLLMFormatter
    @ObservationIgnored private var tryTask: Task<Void, Never>?

    init(settings: DictationSettings, transport: any HTTPTransport) {
        self.settings = settings
        probe = EndpointProbe(transport: transport)
        formatter = LocalLLMFormatter(transport: transport, target: { settings.llmTarget })
        mode = settings.mode
        address = settings.llmEndpoint?.absoluteString ?? ""
        selectedEndpoint = settings.llmEndpoint
        selectedModel = settings.llmModel
    }

    var isCleanupOn: Bool { mode == .cleanup }

    /// The models of the selected server, from the last probe.
    var models: [String] {
        endpoints.first { $0.baseURL == selectedEndpoint }?.models ?? []
    }

    var hasTarget: Bool { selectedEndpoint != nil && selectedModel != nil }

    /// Looks for servers again (the pane calls it when it appears and when the mode is switched on).
    func refresh() async {
        guard isCleanupOn else { return }
        isProbing = true
        endpoints = await probe.discover(custom: settings.llmEndpoint)
        isProbing = false
        // Nothing chosen yet: take the first server that has a model.
        if settings.llmTarget == nil, let first = endpoints.first(where: { !$0.models.isEmpty }) {
            chooseEndpoint(first.baseURL)
        } else if let model = selectedModel, !models.isEmpty, !models.contains(model) {
            chooseModel(models.first)
        }
    }

    func chooseEndpoint(_ url: URL) {
        guard LoopbackPolicy.isAllowed(url) else { return }
        _ = settings.setLLMEndpoint(url.absoluteString)
        selectedEndpoint = url
        address = url.absoluteString
        chooseModel(endpoints.first { $0.baseURL == url }?.models.first)
    }

    func chooseModel(_ model: String?) {
        settings.setLLMModel(model)
        selectedModel = model
    }

    private func applyAddress() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            addressError = false
            return
        }
        if settings.setLLMEndpoint(text) {
            addressError = false
            selectedEndpoint = settings.llmEndpoint
        } else {
            addressError = true
        }
    }

    /// Looks for a server at the typed address.
    func checkAddress() {
        guard !addressError else { return }
        Task { await refresh() }
    }

    /// "Try it": cleans the sample with the chosen model.
    func tryIt() {
        guard tryTask == nil, hasTarget else { return }
        tryState = .running
        let formatter = formatter
        tryTask = Task { [weak self] in
            let sample = Self.sample
            let result = try? await formatter.format(chunk: sample, previousContext: nil)
            guard let self else { return }
            if let result {
                tryState = .result(original: sample, text: result.text, cleaned: result.outcome == .formatted)
            } else {
                tryState = .idle
            }
            tryTask = nil
        }
    }
}
