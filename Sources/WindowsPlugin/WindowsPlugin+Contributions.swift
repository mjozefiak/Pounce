import LintelKit
import LintelUI
import SwiftUI

extension WindowsPlugin {
    public func settingsPane() -> AnyView? {
        AnyView(WindowsSettingsPane(model: paneModel, isActive: runtime != nil))
    }

    /// Read only while the plugin is active; it only reads what `WindowsSettingsModel.refresh()` cached.
    public var settingsStatus: SettingsStatus? {
        let model = paneModel
        return WindowsBanner.derive(model.status) { id in await model.perform(id) }
    }

    public var onboardingSteps: [OnboardingStep] {
        let model = paneModel
        let permissions = context.permissions
        let workspace = context.workspace
        return [
            OnboardingStep(
                id: "windows.setup",
                title: Self.manifest.displayName, symbolName: "rectangle.3.group", text: WindowsSetupView.text,
                makeView: {
                    AnyView(
                        WindowsSetupView(
                            model: model, permissions: permissions,
                            openAccessibility: {
                                guard let url = WindowsPlugin.accessibilitySettingsURL else { return }
                                Task { try? await workspace.open(url) }
                            }))
                })
        ]
    }
}
