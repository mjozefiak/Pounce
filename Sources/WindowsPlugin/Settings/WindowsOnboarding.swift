import LintelKit
import LintelUI
import SwiftUI

/// The welcome step of Window Management (spec: UI/UX): what it does, the Accessibility request, the shortcut
/// safety check with a one-click ⌃⌥ offer, and how windows come back.
struct WindowsSetupView: View {
    @Bindable var model: WindowsSettingsModel
    let permissions: any PermissionsReader
    let openAccessibility: () -> Void
    @Environment(\.lintelTextSize) private var textSize
    @State private var granted = false

    static let text = LocalizedStringResource(
        "Arrange windows in workspaces. Windows of other workspaces are parked in a screen corner.",
        comment: "Window Management welcome step: what the feature does")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "lock.fill")
                    .foregroundStyle(granted ? LintelBrand.statusOk : LintelBrand.statusAttention)
                    .accessibilityHidden(true)
                Text(
                    granted
                        ? "Accessibility is allowed" : "Accessibility is needed to move windows",
                    comment: "Window Management welcome step: the Accessibility state"
                )
                .font(textSize.font(.body))
                Spacer()
                if !granted {
                    Button {
                        openAccessibility()
                    } label: {
                        Text("Open System Settings", comment: "Settings banner button: opens System Settings")
                    }
                }
            }
            if model.needsShortcutWarning {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ShortcutWarning.title(count: model.flagged.count))
                            .font(textSize.font(.body))
                        Text(ShortcutWarning.detail(model.unsafeShortcuts))
                            .font(textSize.font(.callout))
                            .foregroundStyle(LintelBrand.secondaryText)
                    }
                    Spacer()
                    Button {
                        model.useControlOption()
                    } label: {
                        Text(ShortcutWarning.action)
                    }
                }
            }
            Text(
                "If something goes wrong, Lintel puts the windows back when it starts, or use Restore All Windows in the menu bar.",
                comment: "Window Management welcome step: recovery"
            )
            .font(textSize.font(.callout))
            .foregroundStyle(LintelBrand.secondaryText)
            Text(
                "Keep the windows you arrange on one Space.",
                comment: "Window Management welcome step: one Space"
            )
            .font(textSize.font(.callout))
            .foregroundStyle(LintelBrand.secondaryText)
        }
        .task {
            granted = permissions.status(of: .accessibility) == .granted
            model.refreshSafety()
        }
    }
}
