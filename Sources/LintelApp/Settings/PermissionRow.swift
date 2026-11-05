import LintelKit
import LintelUI
import SwiftUI

/// The one permission view (spec D5): name, state in words, why it is needed, who needs it, the accessories the
/// needing plugins add (Meetings' system-audio Test), "Allow Microphone" while macOS has not asked, and the
/// button to System Settings. Dimmed when no enabled feature needs the permission.
struct PermissionRow: View {
    let state: PermissionRowState
    var accessories: [AnyView] = []
    var allow: () -> Void = {}
    let open: () -> Void

    @Environment(\.lintelTextSize) private var textSize
    @Environment(\.settingsHostStyle) private var hostStyle

    private var toneColor: Color {
        switch state.tone {
        case .ok: LintelBrand.statusOk
        case .problem: LintelBrand.statusAttention
        case .neutral: .secondary
        }
    }

    var body: some View {
        if hostStyle == .legacyWindow {
            legacyBody
        } else {
            mainWindowBody
        }
    }

    /// The main window (prototype `set-permissions`): the name, then one line with the state in words (coloured
    /// by tone) and who needs it, and one button. The explanation is the row's `.help` and accessibility help.
    private var mainWindowBody: some View {
        let permission = state.permission
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: permission.symbolName)
                .symbolRenderingMode(.hierarchical)
                .font(textSize.font(.body))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .font(textSize.font(.body, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(stateLine)
                    .font(textSize.font(.callout))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(accessories.indices, id: \.self) { accessories[$0] }
            }
            Spacer(minLength: 12)
            if let title = state.allowTitle {
                Button(action: allow) { Text(title) }
                    .buttonStyle(LintelPrimaryButtonStyle())
            } else if state.tone != .ok {
                openButton
            }
        }
        .help(permission.explanation)
        .opacity(state.isDimmed ? 0.6 : 1)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var openButton: some View {
        let button = Button(action: open) {
            Text("Open System Settings", comment: "Settings banner button: opens a permission's page")
        }
        .accessibilityHint(
            Text(
                "Opens \(state.permission.title) in System Settings",
                comment: "Accessibility hint of the button that opens a permission's settings"))
        if state.tone == .problem {
            button.buttonStyle(LintelPrimaryButtonStyle())
        } else {
            button.buttonStyle(LintelSecondaryButtonStyle())
        }
    }

    /// "Not asked yet · Needed for: Dictation and Meetings", the state in its tone colour.
    private var stateLine: AttributedString {
        var line = AttributedString(state.mainStateText)
        line.foregroundColor = toneColor
        return line + AttributedString(" · " + String(localized: neededText))
    }

    private var neededText: LocalizedStringResource {
        state.pluginNames.isEmpty
            ? LocalizedStringResource(
                "No feature that is on needs it.",
                comment: "Settings → Permissions: a permission no enabled feature needs")
            : LocalizedStringResource(
                "Needed for: \(state.pluginNames.formatted(.list(type: .and)))",
                comment: "Settings → Permissions: the features that need a permission")
    }

    private var legacyBody: some View {
        let permission = state.permission
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.symbolName)
                .symbolRenderingMode(.hierarchical)
                .font(textSize.font(.title3))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(permission.title)
                    .font(textSize.font(.body))
                    .accessibilityAddTraits(.isHeader)
                Label {
                    Text(state.stateText)
                } icon: {
                    Image(systemName: state.status.symbolName)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(toneColor)
                        .accessibilityHidden(true)
                }
                .font(textSize.font(.callout, weight: .medium))
                Text(permission.explanation)
                    .font(textSize.font(.callout))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if state.pluginNames.isEmpty {
                        Text(
                            "No feature that is on needs it.",
                            comment: "Settings → Permissions: a permission no enabled feature needs")
                    } else {
                        Text(
                            "Needed by: \(state.pluginNames.formatted(.list(type: .and)))",
                            comment: "Settings → Permissions: the features that need a permission")
                    }
                }
                .font(textSize.font(.callout))
                .foregroundStyle(.secondary)
                ForEach(accessories.indices, id: \.self) { accessories[$0] }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                if let title = state.allowTitle {
                    Button(action: allow) { Text(title) }
                }
                Button(action: open) {
                    Text("Open System Settings…", comment: "Button that opens a permission's page in System Settings")
                }
                .accessibilityHint(
                    Text(
                        "Opens \(permission.title) in System Settings",
                        comment: "Accessibility hint of the button that opens a permission's settings"))
            }
        }
        .opacity(state.isDimmed ? 0.6 : 1)
        .accessibilityElement(children: .contain)
    }
}
