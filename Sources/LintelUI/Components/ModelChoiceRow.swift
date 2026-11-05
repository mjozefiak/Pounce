import SwiftUI

/// The one-line model summary of a plugin pane in the main window (spec `2026-11-04-lintel-main-window`, step
/// 3.3): "Parakeet Ultra · not installed · Get it in Models". Downloads, folders and removal live in the Models
/// pane only; the link calls the plugin's `PluginContext.openModels(packageID)`.
public struct ModelChoiceRow: View {
    /// What the pane knows about the model.
    public enum State: Hashable, Sendable {
        case installed
        /// The user points to a folder of their own.
        case customFolder
        case downloading
        case notInstalled
    }

    /// Where the summary sits.
    public enum Style: Hashable, Sendable {
        /// A row of its own: the summary on the left, the link on the right.
        case row
        /// The help line under a row's label (prototype `set-dictation`, "Speech model"): smaller, secondary.
        case help
    }

    private let title: String
    private let state: State
    private let style: Style
    private let open: () -> Void
    @Environment(\.lintelTextSize) private var textSize

    public init(title: String, state: State, style: Style = .row, open: @escaping () -> Void) {
        self.title = title
        self.state = state
        self.style = style
        self.open = open
    }

    public var body: some View {
        switch style {
        case .row: rowBody
        case .help: helpBody
        }
    }

    private var helpBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.summary(title: title, state: state))
                .font(textSize.font(.callout))
                .foregroundStyle(.secondary)
            Button(action: open) {
                Text(Self.actionTitle(for: state))
                    .font(textSize.font(.callout))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LintelBrand.accentText)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var rowBody: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Self.summary(title: title, state: state))
                .font(textSize.font(.body))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: open) {
                Text(Self.actionTitle(for: state))
                    .font(textSize.font(.body))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LintelBrand.accentText)
        }
        .accessibilityElement(children: .combine)
    }

    /// "Parakeet Ultra · not installed".
    public static func summary(title: String, state: State) -> String {
        String(
            localized: "\(title) · \(stateTitle(state))",
            comment:
                "Settings model summary: the model's name and its state, for example Parakeet Ultra · not installed"
        )
    }

    public static func stateTitle(_ state: State) -> String {
        switch state {
        case .installed:
            String(localized: "installed", comment: "Settings model summary: the model is on this Mac")
        case .customFolder:
            String(localized: "your folder", comment: "Settings model summary: the model is in a folder the user chose")
        case .downloading:
            String(localized: "downloading", comment: "Settings model summary: the model is being downloaded")
        case .notInstalled:
            String(localized: "not installed", comment: "Settings model summary: the model is not on this Mac")
        }
    }

    /// "Get it in Models" while the model is missing, else "Manage in Models".
    public static func actionTitle(for state: State) -> String {
        switch state {
        case .notInstalled:
            String(localized: "Get it in Models", comment: "Settings model summary link that opens the Models pane")
        case .installed, .customFolder, .downloading:
            String(localized: "Manage in Models", comment: "Settings model summary link that opens the Models pane")
        }
    }
}

/// "Use Downloaded Model" under a plugin pane's `ModelChoiceRow` while the model comes from a folder the user
/// chose: the way back to the model Lintel downloads. Models offers "Choose Folder…" but cannot tell that a
/// folder is set, so the pane that knows shows this (a link, like the summary's).
public struct UseDownloadedModelButton: View {
    private let action: () -> Void
    @Environment(\.lintelTextSize) private var textSize

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(Self.title).font(textSize.font(.callout))
        }
        .buttonStyle(.plain)
        .foregroundStyle(LintelBrand.accentText)
    }

    public static var title: String {
        String(localized: "Use Downloaded Model", comment: "Button that stops using the chosen model folder")
    }
}
