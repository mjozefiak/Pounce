import LintelKit
import LintelUI
import SwiftUI

/// What the Features pane's controls do, kept out of the view so the binding to `PluginHost` is tested
/// (spec step 1.2b).
struct FeatureControls {
    let host: PluginHost
    /// Called after a plugin was turned on or off or erased, so shortcuts and menus follow.
    let onChange: () -> Void

    func isEnabled(_ id: PluginID) -> Bool {
        host.isEnabled(id)
    }

    /// The switch: persists `plugins.<id>.enabled` and activates or deactivates the plugin.
    func setEnabled(_ enabled: Bool, for id: PluginID) async {
        await host.setEnabled(enabled, for: id)
        onChange()
    }

    /// "Erase Data". Returns the error message to show, or `nil` when it worked. `alsoDeleteKeptCopies` is the
    /// sheet's "Also delete kept copies" checkbox; ignored until Notes exists (spec `2026-11-04-notes-workspace`,
    /// step 4.6 deletes the copies).
    func erase(_ id: PluginID, alsoDeleteKeptCopies: Bool = false) async -> String? {
        defer { onChange() }
        do {
            try await host.eraseData(for: id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The "Result order" list (issue #5): the plugins with result sections, in the user's order.
struct SectionOrderControls {
    let host: PluginHost
    let settings: AppSettings

    /// Plugins that contribute search sections, in the current order.
    var ordered: [PluginHost.Entry] {
        SectionOrder.sorted(host.entries.filter { !$0.plugin.searchSources.isEmpty }, saved: settings.sectionOrder)
    }

    /// Moves a section up (−1) or down (+1) and saves the whole order in `app.sectionOrder`.
    func move(_ id: PluginID, by offset: Int) {
        settings.sectionOrder = SectionOrder.moving(id, by: offset, in: ordered.map(\.manifest.id)).map(\.rawValue)
    }

    /// Drag and drop: puts `id` at `index` of the current order and saves the whole order.
    func move(_ id: PluginID, to index: Int) {
        var ids = ordered.map(\.manifest.id)
        guard let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        ids.insert(id, at: min(max(index, 0), ids.count))
        settings.sectionOrder = ids.map(\.rawValue)
    }

    func restoreDefault() {
        settings.sectionOrder = []
    }
}

/// Settings → Features: every plugin with its switch (or the "Always on" chip of a plugin that cannot be turned
/// off), the order of the result sections and, under Advanced, "Erase Data". The main window draws it on the
/// `SettingsPane` template (prototype `set-features`, spec step 4.1); the old window keeps `LegacyFeaturesPane`.
/// The "All set" banner is the host's (`ShellPaneBanners.features`).
struct FeaturesPane: View {
    let controls: FeatureControls
    let order: SectionOrderControls?

    @Environment(\.settingsHostStyle) private var hostStyle

    init(host: PluginHost, settings: AppSettings? = nil, onChange: @escaping () -> Void) {
        controls = FeatureControls(host: host, onChange: onChange)
        order = settings.map { SectionOrderControls(host: host, settings: $0) }
    }

    var body: some View {
        if hostStyle == .legacyWindow {
            LegacyFeaturesPane(controls: controls, order: order)
        } else {
            FeaturesPaneContent(controls: controls, order: order)
        }
    }
}

/// What the right end of a feature row shows, from the manifest only: a plugin with `canBeDisabled == false`
/// (Notes) gets the "Always on" chip instead of a switch.
enum FeatureAccessory: Equatable {
    case toggle
    case alwaysOn

    init(_ manifest: PluginManifest) {
        self = manifest.canBeDisabled ? .toggle : .alwaysOn
    }
}

extension PluginID {
    /// Row ids per section: the grouped form is one list, and equal ids in two sections make it draw a row in the
    /// wrong place.
    fileprivate var resultOrderRowID: String { "result-order:\(rawValue)" }
    fileprivate var eraseRowID: String { "erase:\(rawValue)" }
}

/// The main window's Features pane: the feature list, Result order with its one-line footer, and a collapsed
/// Advanced section with each feature's "Erase Data" and "Restore Default Order".
struct FeaturesPaneContent: View {
    let controls: FeatureControls
    let order: SectionOrderControls?

    @Environment(\.lintelTextSize) private var textSize
    @State private var eraseError: String?

    var body: some View {
        SettingsPane {
            Section {
                ForEach(controls.host.entries, id: \.manifest.id) { entry in
                    FeatureSwitchRow(
                        manifest: entry.manifest,
                        state: entry.state,
                        isEnabled: controls.isEnabled(entry.manifest.id),
                        setEnabled: { enabled in
                            Task { await controls.setEnabled(enabled, for: entry.manifest.id) }
                        })
                }
            }
            if let order, order.ordered.count > 1 {
                ResultOrderSection(order: order)
            }
        } advanced: {
            ForEach(controls.host.entries, id: \.manifest.id.eraseRowID) { entry in
                FeatureEraseRow(manifest: entry.manifest) { alsoDeleteKeptCopies in
                    Task {
                        eraseError = await controls.erase(
                            entry.manifest.id, alsoDeleteKeptCopies: alsoDeleteKeptCopies)
                    }
                }
            }
            if let order, order.ordered.count > 1 {
                LabeledContent {
                    Button {
                        order.restoreDefault()
                    } label: {
                        Text("Restore Default Order", comment: "Button that restores the default result order")
                            .font(textSize.font(.body))
                    }
                    .disabled(order.settings.sectionOrder.isEmpty)
                } label: {
                    Text("Result order", comment: "Settings → Features: section title of the result order")
                        .font(textSize.font(.body))
                }
            }
        }
        .alert(
            Text("The data could not be erased.", comment: "Alert title when Erase Data fails"),
            isPresented: Binding(get: { eraseError != nil }, set: { if !$0 { eraseError = nil } })
        ) {
            Button {
                eraseError = nil
            } label: {
                Text("OK", comment: "Button that dismisses an alert")
            }
        } message: {
            Text(eraseError ?? "")
        }
    }
}

/// One feature in the main window: its symbol and name, a state line only while it starts or after it failed,
/// and its switch or the "Always on" chip.
struct FeatureSwitchRow: View {
    let manifest: PluginManifest
    let state: PluginState
    let isEnabled: Bool
    let setEnabled: (Bool) -> Void

    @Environment(\.lintelTextSize) private var textSize

    /// The line under the name: only what the switch does not already say.
    static func detail(for state: PluginState) -> String? {
        switch state {
        case .active, .disabled:
            nil
        case .activating:
            String(localized: "Starting…", comment: "Feature state")
        case .failed(let error):
            String(
                localized: "Unavailable: \(error.localizedDescription)",
                comment: "Feature state with the error message")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: manifest.symbolName)
                .symbolRenderingMode(.hierarchical)
                .font(textSize.font(.body))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(manifest.displayName)
                    .font(textSize.font(.body, weight: .semibold))
                if let detail = Self.detail(for: state) {
                    Text(verbatim: detail)
                        .font(textSize.font(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            switch FeatureAccessory(manifest) {
            case .alwaysOn:
                AlwaysOnChip()
            case .toggle:
                Toggle(isOn: Binding(get: { isEnabled }, set: { setEnabled($0) })) {
                    Text(manifest.displayName)
                }
                .labelsHidden()
                .toggleStyle(.switch)
            }
        }
        .accessibilityElement(children: FeatureAccessory(manifest) == .alwaysOn ? .combine : .contain)
    }
}

/// The chip of a feature that cannot be turned off.
struct AlwaysOnChip: View {
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        Text("Always on", comment: "Settings → Features: chip of a feature that cannot be turned off")
            .font(textSize.font(.caption1))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
    }
}

/// "Erase Data…" of one feature, under Advanced, with the shared confirmation.
struct FeatureEraseRow: View {
    let manifest: PluginManifest
    /// Receives the "Also delete kept copies" checkbox (always `false` without one).
    let erase: (Bool) -> Void

    @Environment(\.lintelTextSize) private var textSize
    @State private var confirmsErase = false

    /// The features whose data Notes can keep copies of (owner decision L1-39).
    static let featuresWithNotesCopies: Set<PluginID> = ["meetings", "dictation"]

    /// Erase Data in the main window: for Meetings and Dictation it also says that copies edited or commented
    /// on in Notes stay, with the "Also delete kept copies" checkbox. DEBUG only until Notes ships (spec
    /// `2026-11-04-notes-workspace`, step 7.1 removes the guard); release builds show the words as today.
    static func confirmation(for manifest: PluginManifest) -> DestructiveConfirmation {
        let confirmation = FeatureRow.confirmation(for: manifest)
        #if DEBUG
        guard featuresWithNotesCopies.contains(manifest.id) else { return confirmation }
        return confirmation.with(option: .keptNotesCopies)
        #else
        return confirmation
        #endif
    }

    var body: some View {
        LabeledContent {
            Button {
                confirmsErase = true
            } label: {
                Text("Erase Data…", comment: "Settings button that deletes a feature's data")
                    .font(textSize.font(.body))
            }
            .accessibilityLabel(
                Text(
                    "Erase Data of \(String(localized: manifest.displayName))…",
                    comment: "Accessibility label of a feature's Erase Data button"))
        } label: {
            Text(manifest.displayName)
                .font(textSize.font(.body))
        }
        .destructiveConfirmation(
            isPresented: $confirmsErase, Self.confirmation(for: manifest), onConfirmWithOption: erase)
    }
}

/// "Result order" (prototype `set-features`): the search sections numbered in the user's order, reordered by
/// dragging a row, or with each row's Move Up and Move Down buttons (reachable with Tab, shown while the row is
/// hovered or one of them has focus); VoiceOver and the context menu offer the same two moves.
struct ResultOrderSection: View {
    let order: SectionOrderControls

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        let entries = order.ordered
        Section {
            ForEach(Array(entries.enumerated()), id: \.element.manifest.id.resultOrderRowID) { index, entry in
                ResultOrderRow(order: order, entry: entry, index: index, count: entries.count) { raw in
                    entries.contains(where: { $0.manifest.id.rawValue == raw })
                }
            }
        } header: {
            Text("Result order", comment: "Settings → Features: section title of the result order")
                .settingsSectionHeader()
        } footer: {
            SettingsFooter(
                LocalizedStringResource(
                    "Drag to change the order in the launcher.",
                    comment: "Settings → Features: footer of the result order"))
        }
    }
}

/// One row of "Result order": its number and name, the Move Up and Move Down buttons and the drag handle.
struct ResultOrderRow: View {
    let order: SectionOrderControls
    let entry: PluginHost.Entry
    let index: Int
    let count: Int
    /// Whether a dropped string is one of this list's plugin ids.
    let accepts: (String) -> Bool

    /// Which of the two buttons has keyboard focus.
    enum MoveButton: Hashable {
        case up
        case down
    }

    @Environment(\.lintelTextSize) private var textSize
    @State private var isHovered = false
    @FocusState private var focusedButton: MoveButton?

    var canMoveUp: Bool { index > 0 }
    var canMoveDown: Bool { index < count - 1 }

    var body: some View {
        let id = entry.manifest.id
        let name = String(localized: entry.manifest.displayName)
        HStack(spacing: 10) {
            Text(verbatim: "\(index + 1). \(name)")
                .font(textSize.font(.body))
                .accessibilityHidden(true)
            Spacer()
            HStack(spacing: 2) {
                moveButton(.up, enabled: canMoveUp) { order.move(id, by: -1) }
                moveButton(.down, enabled: canMoveDown) { order.move(id, by: 1) }
            }
            .opacity(isHovered || focusedButton != nil ? 1 : 0)
            Image(systemName: "line.3.horizontal")
                .font(textSize.font(.body))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .draggable(id.rawValue)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, accepts(raw) else { return false }
            order.move(PluginID(rawValue: raw), to: index)
            return true
        }
        .contextMenu {
            Button {
                order.move(id, by: -1)
            } label: {
                Text("Move Up", comment: "Button that moves a result section up")
            }
            .disabled(!canMoveUp)
            Button {
                order.move(id, by: 1)
            } label: {
                Text("Move Down", comment: "Button that moves a result section down")
            }
            .disabled(!canMoveDown)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                "\(name), position \(index + 1) of \(count)",
                comment: "Accessibility label of a result section in the order list")
        )
        .accessibilityAction(named: Text("Move Up", comment: "Button that moves a result section up")) {
            order.move(id, by: -1)
        }
        .accessibilityAction(named: Text("Move Down", comment: "Button that moves a result section down")) {
            order.move(id, by: 1)
        }
    }

    private func moveButton(_ button: MoveButton, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                switch button {
                case .up: Text("Move Up", comment: "Button that moves a result section up")
                case .down: Text("Move Down", comment: "Button that moves a result section down")
                }
            } icon: {
                Image(systemName: button == .up ? "chevron.up" : "chevron.down")
                    .font(textSize.font(.callout))
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .focused($focusedButton, equals: button)
        .help(
            button == .up
                ? Text("Move Up", comment: "Button that moves a result section up")
                : Text("Move Down", comment: "Button that moves a result section down"))
    }
}
