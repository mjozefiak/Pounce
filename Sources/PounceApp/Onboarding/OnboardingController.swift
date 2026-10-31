import AppKit
import SwiftUI

/// The first-launch Shortcut step (Q10, spec step 1.2b): a recorder prefilled with the default shortcut,
/// "Use This Shortcut" and "Skip". Skipping keeps the automatic default. Phase 4's welcome screen will
/// combine this step with the plugins' `onboardingSteps`.
final class OnboardingController: NSObject, NSWindowDelegate {
    private let hotkeys: HotkeyService
    private let settings: AppSettings
    private var window: NSWindow?

    /// False in QA mode: the window is ordered front without activating Pounce.
    var activatesApp = true

    init(hotkeys: HotkeyService, settings: AppSettings) {
        self.hotkeys = hotkeys
        self.settings = settings
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func showShortcutStep() {
        hotkeys.refreshDefault()
        let view = ShortcutStepView(
            hotkeys: hotkeys,
            onUse: { [weak self] in self?.finish(skipped: false) },
            onSkip: { [weak self] in self?.finish(skipped: true) }
        )
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Welcome to Pounce", comment: "Onboarding window title")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        if activatesApp {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    /// Closing the window counts as skipping.
    func windowWillClose(_ notification: Notification) {
        if !settings.shortcutOnboardingCompleted {
            settings.shortcutOnboardingCompleted = true
        }
    }

    private func finish(skipped: Bool) {
        if skipped {
            hotkeys.resetToDefault()
        }
        settings.shortcutOnboardingCompleted = true
        window?.close()
        window = nil
    }
}

struct ShortcutStepView: View {
    let hotkeys: HotkeyService
    let onUse: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "keyboard")
                    .symbolRenderingMode(.hierarchical)
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose a Shortcut", comment: "Onboarding step title")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        "Press this shortcut anywhere to open Pounce. Keep the suggested one or record your own.",
                        comment: "Onboarding step explanation"
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent {
                MainShortcutRecorder(hotkeys: hotkeys)
            } label: {
                Text("Open Pounce", comment: "Settings label of the main shortcut")
            }
            if hotkeys.spotlightHoldsCommandSpace {
                GroupBox {
                    SpotlightShortcutBanner()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("You can change it later in Settings → General.", comment: "Onboarding hint")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(action: onSkip) {
                    Text("Skip", comment: "Onboarding button that keeps the default shortcut")
                }
                .keyboardShortcut(.cancelAction)
                Button(action: onUse) {
                    Text("Use This Shortcut", comment: "Onboarding button that confirms the shortcut")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}
