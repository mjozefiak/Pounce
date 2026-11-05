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

    private var toneColor: Color {
        switch state.tone {
        case .ok: LintelBrand.statusOk
        case .problem: LintelBrand.statusAttention
        case .neutral: .secondary
        }
    }

    var body: some View {
        let permission = state.permission
        HStack(alignment: .top, spacing: 12) {
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
