import Foundation
import LintelKit
import LintelSpeech
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
        var isInstalled: Bool { state == .installed }
        var isDownloading: Bool { progress != nil }

        /// "Used by Meetings, Dictation (off)"; `nil` when no plugin uses it.
        var usedByText: String? {
            guard !usedBy.isEmpty else { return nil }
            let names = usedBy.map(\.label).formatted(.list(type: .and))
            return String(localized: "Used by \(names)", comment: "Models pane: the features that use a model")
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
                return String(localized: "Not installed", comment: "Models pane: the model is not on this Mac")
            }
        }
    }

    /// The kinds in the order the pane shows them.
    static let kindOrder: [ModelKind] = [.speech, .llm, .diarization]

    private(set) var states: [String: InventoryState] = [:]
    private(set) var progress: [String: ModelProgress] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var busy: Set<String> = []
    private(set) var plugins: [PluginUsages] = []
    /// The row `openModels(packageID)` asked for; the pane scrolls to it once.
    var scrollTarget: String?

    @ObservationIgnored let inventory: any ModelInventory
    @ObservationIgnored private let readUsages: () -> [PluginUsages]
    @ObservationIgnored private let pickFolder: () -> URL?
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loggedUnknown: Set<String> = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.lintelapp", category: "window")

    init(
        inventory: any ModelInventory, usages: @escaping () -> [PluginUsages],
        pickFolder: @escaping () -> URL? = { nil }
    ) {
        self.inventory = inventory
        self.readUsages = usages
        self.pickFolder = pickFolder
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
        let known = Set(inventory.catalog.map(\.id))
        return Set(
            plugins.filter(\.isEnabled).flatMap(\.usages)
                .filter { $0.isRequired && $0.isSelected && known.contains($0.packageID) }
                .map(\.packageID)
        ).filter { states[$0] != .installed }
    }

    /// The pane's banner through the host's derivation seam: "1 model is needed", or none.
    var banner: StatusDerivation.Banner? {
        let count = neededIDs.count
        guard count > 0 else { return nil }
        return StatusDerivation.Banner(
            level: .attention,
            title: String(localized: "\(count) models are needed", comment: "Models pane banner: required models"),
            detail: String(
                localized: "Features that are on can't work without them. Download them below.",
                comment: "Models pane banner detail: required models are missing"),
            actions: [])
    }

    // MARK: Reading

    /// Reads the plugins' usages and every package's state again (the pane appearing, after every action).
    func refresh() async {
        plugins = readUsages()
        logUnknownPackages()
        var result: [String: InventoryState] = [:]
        for model in inventory.catalog {
            result[model.id] = await inventory.state(of: model.id)
        }
        states = result
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
        if await isInUse() {
            errors[id] = Self.inUseMessage
            return
        }
        let releases = guards.map { $0.reserveRemoval() }
        defer {
            for release in releases { release() }
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
