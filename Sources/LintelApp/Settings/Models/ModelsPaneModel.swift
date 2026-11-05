import Foundation
import LintelKit
import LintelSpeech
import LintelUI
import Observation
import os

/// What Settings → Models shows and does (spec `2026-11-04-lintel-main-window`, step 3.2, D6): every catalog
/// package with its size and state, "used by" from the plugins' `modelUsage`, download with progress, removal
/// and "Choose Folder…". Kept out of the view so it is tested; the files are reached only through `ModelInventory`.
///
/// Removal is refused while any usage **of the same kind** is in use (of any plugin, on or off, whether or not it
/// lists that package: a plugin can switch its model while a run on the old one continues) or while a shared
/// lease holds the package. All of those usages' `reserveRemoval`s are held during the removal, an idle warm
/// model of the kind is unloaded inside it, and `ModelManager.delete(_:unless:)` asks again right before the
/// files go.
@Observable
final class ModelsPaneModel {
    /// One plugin's declared models.
    struct PluginUsages {
        let pluginID: String
        let pluginName: String
        /// Enabled in Features (a failed plugin counts: it is still on).
        let isEnabled: Bool
        let usages: [ModelUsage]
    }

    /// One "used by" chip.
    struct UsedBy: Identifiable, Equatable {
        let pluginID: String
        let pluginName: String
        let role: String
        let isEnabled: Bool
        let canChooseFolder: Bool

        var id: String { pluginID }

        /// "Meetings", or "Meetings (off)" for a plugin that is turned off.
        var label: String {
            isEnabled
                ? pluginName
                : String(
                    localized: "\(pluginName) (off)", comment: "Models pane chip: a feature that is off uses the model")
        }
    }

    struct Row: Identifiable, Equatable {
        let model: CatalogModel
        let state: InventoryState
        let progress: ModelProgress?
        let errorMessage: String?
        let usedBy: [UsedBy]
        /// An enabled plugin requires it and it is not installed.
        let isNeeded: Bool
        let isBusy: Bool

        var id: String { model.id }

        /// The name shown: the catalog title, except the speaker model, which the prototype calls "Speaker
        /// separation" (the package title is a technical name).
        var title: String {
            model.kind == .diarization
                ? String(localized: "Speaker separation", comment: "Models pane: the speaker recognition model")
                : model.title
        }

        /// The primary button is the one the user must press: a needed model's Download.
        var isPrimaryAction: Bool { isNeeded && !isInstalled && !isDownloading }
        var isInstalled: Bool { state == .installed }
        var isDownloading: Bool { progress != nil }

        /// "Used by Meetings, Dictation (off)"; `nil` when no plugin uses it.
        var usedByText: String? {
            guard let names = usedByNames else { return nil }
            return String(localized: "Used by \(names)", comment: "Models pane: the features that use a model")
        }

        /// "Meetings and Dictation (off)"; `nil` when no plugin uses it.
        var usedByNames: String? {
            guard !usedBy.isEmpty else { return nil }
            return usedBy.map(\.label).formatted(.list(type: .and))
        }

        var stateText: String {
            if let progress {
                let percent = progress.fraction.formatted(.percent.precision(.fractionLength(0)))
                return String(localized: "Downloading \(percent)", comment: "Models pane: a download in progress")
            }
            switch state {
            case .installed:
                return String(localized: "Installed", comment: "Models pane: the model is on this Mac")
            case .partial:
                return String(
                    localized: "Partly downloaded", comment: "Models pane: an interrupted download can continue")
            case .missing:
                return String(localized: "Not downloaded", comment: "Models pane: the model is not on this Mac")
            }
        }
    }

    /// The kinds in the order the pane shows them.
    static let kindOrder: [ModelKind] = [.speech, .llm, .diarization]

    /// One card of the pane: "Speech" (speech models, then the speaker model) and "Writing" (language models).
    struct Section: Identifiable, Equatable {
        let id: String
        let kinds: [ModelKind]

        var title: String {
            switch id {
            case "speech": String(localized: "Speech", comment: "Models pane section: speech models")
            case "writing": String(localized: "Writing", comment: "Models pane section: built-in language models")
            default: id
            }
        }
    }

    private(set) var states: [String: InventoryState] = [:]
    private(set) var progress: [String: ModelProgress] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var busy: Set<String> = []
    private(set) var plugins: [PluginUsages] = []
    /// `false` until the first `refresh()` has read every state: before that no model counts as missing, so the
    /// "needed" banner and badges do not flash (and VoiceOver does not announce them) while the pane opens.
    private(set) var hasLoaded = false
    /// The package the user asked to remove, waiting for the confirmation.
    private(set) var pendingRemoval: String?
    /// The row `openModels(packageID)` asked for; the pane scrolls to it once.
    var scrollTarget: String?

    @ObservationIgnored let inventory: any ModelInventory
    @ObservationIgnored private let readUsages: () -> [PluginUsages]
    @ObservationIgnored private let pickFolder: () -> URL?
    /// The folder "Show in Finder" reveals (`Models/`, the parent of the per-kind folders).
    @ObservationIgnored let modelsDirectory: URL
    @ObservationIgnored private let revealInFinder: (URL) -> Void
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loggedUnknown: Set<String> = []
    /// Bumped by every `refresh()`; a refresh that was overtaken by a newer one does not write its states.
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private let logger = Logger(subsystem: "com.lintelapp", category: "window")

    init(
        inventory: any ModelInventory, usages: @escaping () -> [PluginUsages],
        pickFolder: @escaping () -> URL? = { nil }, modelsDirectory: URL = URL(filePath: "/"),
        revealInFinder: @escaping (URL) -> Void = { _ in }
    ) {
        self.inventory = inventory
        self.readUsages = usages
        self.pickFolder = pickFolder
        self.modelsDirectory = modelsDirectory
        self.revealInFinder = revealInFinder
        self.plugins = usages()
    }

    // MARK: Rows

    /// The kinds that have packages, in `kindOrder`, then any other kind in catalog order.
    var kinds: [ModelKind] {
        var result = Self.kindOrder.filter { kind in inventory.catalog.contains { $0.kind == kind } }
        for model in inventory.catalog where !result.contains(model.kind) { result.append(model.kind) }
        return result
    }

    var rows: [Row] { kinds.flatMap(rows(of:)) }

    /// The cards, in the order shown; a card with no packages is left out.
    var sections: [Section] {
        var result: [Section] = []
        let speech = kinds.filter { $0 == .speech || $0 == .diarization }
        if !speech.isEmpty { result.append(Section(id: "speech", kinds: speech)) }
        if kinds.contains(.llm) { result.append(Section(id: "writing", kinds: [.llm])) }
        for kind in kinds where ![.speech, .diarization, .llm].contains(kind) {
            result.append(Section(id: kind.rawValue, kinds: [kind]))
        }
        return result
    }

    func rows(in section: Section) -> [Row] { section.kinds.flatMap(rows(of:)) }

    /// "Needs about 3.3 GB of memory while writing.": the catalog's figure for the language model the user most
    /// likely runs (an installed one, else the smallest that can be downloaded); `nil` when the catalog has none.
    var writingMemoryFooter: String? {
        let writing = rows(of: .llm).filter { $0.model.residentBytes != nil }
        let chosen =
            writing.filter(\.isInstalled).max { ($0.model.residentBytes ?? 0) < ($1.model.residentBytes ?? 0) }
            ?? writing.filter { $0.model.canDownload }.min {
                ($0.model.residentBytes ?? 0) < ($1.model.residentBytes ?? 0)
            }
        guard let bytes = chosen?.model.residentBytes else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return String(
            localized: "Needs about \(size) of memory while writing.",
            comment: "Models pane footer under Writing: memory a loaded language model takes")
    }

    /// The rows of one kind, in catalog order.
    func rows(of kind: ModelKind) -> [Row] {
        inventory.catalog.filter { $0.kind == kind }.map(row)
    }

    private func row(_ model: CatalogModel) -> Row {
        let state = states[model.id] ?? .missing
        return Row(
            model: model, state: state, progress: progress[model.id], errorMessage: errors[model.id],
            usedBy: usedBy(model.id), isNeeded: neededIDs.contains(model.id), isBusy: busy.contains(model.id))
    }

    private func usedBy(_ id: String) -> [UsedBy] {
        plugins.compactMap { plugin in
            let selected = plugin.usages.filter { $0.packageID == id && $0.isSelected }
            guard let first = selected.first else { return nil }
            return UsedBy(
                pluginID: plugin.pluginID, pluginName: plugin.pluginName, role: String(localized: first.role),
                isEnabled: plugin.isEnabled, canChooseFolder: selected.contains { $0.chooseFolder != nil })
        }
    }

    /// The packages an enabled plugin requires (and has selected) that are not installed. A usage of a disabled
    /// plugin never counts; an id outside the catalog is ignored.
    var neededIDs: Set<String> {
        guard hasLoaded else { return [] }
        let known = Set(inventory.catalog.map(\.id))
        return Set(
            plugins.filter(\.isEnabled).flatMap(\.usages)
                .filter { $0.isRequired && $0.isSelected && known.contains($0.packageID) }
                .map(\.packageID)
        ).filter { states[$0] != .installed }
    }

    /// The pane's banner through the host's derivation seam: "1 model is needed" with a primary button that
    /// downloads the first needed model, or none.
    var banner: StatusDerivation.Banner? {
        let needed = neededIDs
        guard !needed.isEmpty,
            let first = inventory.catalog.first(where: { needed.contains($0.id) && $0.canDownload })
                ?? inventory.catalog.first(where: { needed.contains($0.id) })
        else { return nil }
        let count = needed.count
        let detail: String
        if count == 1, let names = row(first).usedByNames {
            detail = String(
                localized: "\(first.title) is used by \(names).",
                comment: "Models pane banner detail: one model is needed")
        } else {
            detail = String(
                localized: "Features that are on can't work without them. Download them below.",
                comment: "Models pane banner detail: required models are missing")
        }
        let id = first.id
        let action = SettingsStatusAction(
            title: LocalizedStringResource(
                "Download \(first.title)", comment: "Models pane banner button: downloads the first needed model"),
            destination: .plugin(id: "models.download", perform: { [weak self] in self?.download(id) }))
        return StatusDerivation.Banner(
            level: .attention,
            title: String(localized: "\(count) models are needed", comment: "Models pane banner: required models"),
            detail: detail,
            actions: first.canDownload ? [action] : [])
    }

    // MARK: Reading

    /// Reads the plugins' usages and every package's state again (the pane appearing, after every action).
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        plugins = readUsages()
        logUnknownPackages()
        var result: [String: InventoryState] = [:]
        for model in inventory.catalog {
            result[model.id] = await inventory.state(of: model.id)
        }
        guard generation == refreshGeneration else { return }
        states = result
        hasLoaded = true
    }

    private func logUnknownPackages() {
        let known = Set(inventory.catalog.map(\.id))
        for id in Set(plugins.flatMap(\.usages).map(\.packageID)).subtracting(known).subtracting(loggedUnknown) {
            loggedUnknown.insert(id)
            // A package id is not sensitive.
            logger.error("Unknown model package \(id, privacy: .public) in modelUsage")
        }
    }

    // MARK: Download

    func download(_ id: String) {
        guard downloads[id] == nil, inventory.catalog.contains(where: { $0.id == id && $0.canDownload }) else {
            return
        }
        errors[id] = nil
        let total = inventory.catalog.first { $0.id == id }?.bytes ?? 0
        progress[id] = ModelProgress(bytesDone: 0, bytesTotal: total)
        let inventory = inventory
        downloads[id] = Task { [weak self] in
            do {
                try await inventory.install(id) { value in
                    Task { @MainActor in
                        // A late report after the download ended must not bring the bar back.
                        guard let self, self.downloads[id] != nil else { return }
                        self.progress[id] = value
                    }
                }
            } catch is CancellationError {
            } catch {
                self?.errors[id] = Self.message(for: error)
            }
            guard let self else { return }
            self.progress[id] = nil
            self.downloads[id] = nil
            await self.refresh()
        }
    }

    func cancelDownload(_ id: String) {
        downloads[id]?.cancel()
    }

    /// Resolves once the download of `id` has ended (tests).
    func waitForDownload(_ id: String) async {
        await downloads[id]?.value
    }

    // MARK: Remove

    /// "Remove" asks first: the files are several gigabytes and come back only by downloading them again.
    func requestRemoval(_ id: String) {
        guard inventory.catalog.contains(where: { $0.id == id }), !busy.contains(id) else { return }
        pendingRemoval = id
    }

    /// Cancel (or Esc) in the confirmation: nothing is deleted.
    func cancelRemoval() { pendingRemoval = nil }

    /// The confirmation's "Remove Model": removes the pending package.
    @discardableResult
    func confirmRemoval() -> Task<Void, Never>? {
        guard let id = pendingRemoval else { return nil }
        pendingRemoval = nil
        return Task { await remove(id) }
    }

    /// The confirmation for the pending removal.
    var removalConfirmation: DestructiveConfirmation {
        let title = inventory.catalog.first { $0.id == pendingRemoval }?.title ?? ""
        return Self.removalConfirmation(title: title)
    }

    static func removalConfirmation(title: String) -> DestructiveConfirmation {
        DestructiveConfirmation(
            prompt: LocalizedStringResource("Remove \(title)?", comment: "Meetings model card: confirmation title"),
            detail: LocalizedStringResource(
                "This model is shared with other Lintel features. It will be downloaded again the next time one of them needs it.",
                comment: "Meetings model card: what removing a shared model means"),
            confirmTitle: LocalizedStringResource(
                "Remove Model", comment: "Button that deletes the downloaded speech model"),
            legacyTitleVisible: true)
    }

    /// Removes the downloaded package (never a folder the user chose). Refused with the in-use message while a
    /// usage of the same kind or a shared lease holds it; see the type's documentation.
    func remove(_ id: String) async {
        guard let model = inventory.catalog.first(where: { $0.id == id }), !busy.contains(id) else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        plugins = readUsages()
        let guards = plugins.flatMap(\.usages).filter { $0.kind == model.kind }
        let inventory = inventory
        let isInUse: @Sendable () async -> Bool = { await Self.isInUse(id, guards: guards, inventory: inventory) }
        // Reserved before the first check, so nothing can start using the model between the check and the delete.
        let releases = guards.map { $0.reserveRemoval() }
        defer {
            for release in releases { release() }
        }
        if await isInUse() {
            errors[id] = Self.inUseMessage
            return
        }
        // The warm copy goes first, inside the reservation, so the file is not open and stops serving requests.
        await inventory.evictIdle(model.kind)
        do {
            errors[id] = try await inventory.delete(id, unless: isInUse) ? nil : Self.inUseMessage
        } catch {
            errors[id] = Self.message(for: error)
        }
        await refresh()
    }

    private static func isInUse(_ id: String, guards: [ModelUsage], inventory: any ModelInventory) async -> Bool {
        for usage in guards where await usage.isInUse() { return true }
        return await inventory.isLeased(id)
    }

    // MARK: Folder

    /// "Choose Folder…" for the plugin `pluginID`: the folder is checked, then handed to that plugin's usage, which
    /// writes its own folder key.
    func chooseFolder(_ id: String, for pluginID: String) async {
        let usage = plugins.first { $0.pluginID == pluginID }?.usages.first {
            $0.packageID == id && $0.chooseFolder != nil
        }
        guard let usage, let choose = usage.chooseFolder, !busy.contains(id), let folder = pickFolder() else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        errors[id] = nil
        do {
            try await inventory.verify(folder: folder, for: id)
            choose(folder)
        } catch {
            errors[id] = Self.message(for: error)
        }
        await refresh()
    }

    // MARK: Storage

    /// Total size of the installed catalog packages: the catalog's own sizes, no scan of the disk.
    var installedBytes: Int {
        inventory.catalog.filter { states[$0.id] == .installed }.reduce(0) { $0 + $1.bytes }
    }

    /// "1.1 GB in Application Support", or "Nothing downloaded yet."
    var storageDetail: String {
        guard installedBytes > 0 else {
            return String(localized: "Nothing downloaded yet.", comment: "Models pane storage: no model is downloaded")
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(installedBytes), countStyle: .file)
        return String(
            localized: "\(size) in Application Support", comment: "Models pane storage: the size of the downloads")
    }

    /// "Show in Finder": reveals the models folder through the injected port.
    func showInFinder() {
        revealInFinder(modelsDirectory)
    }

    // MARK: Messages

    static var inUseMessage: String {
        String(
            localized: "The model is in use right now. Try again in a moment.",
            comment: "Models pane error when a model in use cannot be removed")
    }

    static func message(for error: any Error) -> String {
        guard let error = error as? ModelError else {
            return String(
                localized: "The download did not finish. Check the connection and try again.",
                comment: "Models pane error after a failed download")
        }
        switch error {
        case .insufficientSpace(let needed, _):
            let size = ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file)
            return String(
                localized: "Not enough free space. The model needs \(size).",
                comment: "Models pane error when the disk is too full")
        case .checksumMismatch, .sizeMismatch:
            return String(
                localized: "A file does not match the expected checksum, so it was not used.",
                comment: "Models pane error after a failed checksum")
        case .disallowedHost, .httpStatus:
            return String(
                localized: "The download was refused by the server. Try again later.",
                comment: "Models pane error after the download server answered with an error")
        case .folderIncomplete(let missing):
            return String(
                localized: "This folder is missing \(missing.count) of the model's files.",
                comment: "Models pane error when a chosen model folder is incomplete")
        case .notInstalled:
            return String(localized: "The model is not installed.", comment: "Models pane error")
        }
    }
}
