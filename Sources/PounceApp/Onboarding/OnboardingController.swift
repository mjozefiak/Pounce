import AppKit
import PounceKit
import SwiftUI

/// The first-launch steps: the Shortcut step (Q10, spec step 1.2b), a recorder prefilled with the
/// default shortcut, "Use This Shortcut" and "Skip" (skipping keeps the automatic default), followed by
/// the active plugins' `onboardingSteps` (Phase 2: the clipboard step), one at a time in the same window.
///
/// Each step is shown once: the Shortcut step until `app.onboarding.shortcutCompleted`, a plugin step
/// until its id is in `app.onboarding.completedSteps`. A plugin step added by an update is shown on the
/// next launch. Closing the window skips the step on screen.
final class OnboardingController: NSObject, NSWindowDelegate {
    private let hotkeys: HotkeyService
    private let settings: AppSettings
    private let pluginSteps: () -> [OnboardingStep]
    private var window: NSWindow?
    /// The plugin step on screen, if any.
    private(set) var currentPluginStep: String?

    /// False in QA mode: the window is ordered front without activating Pounce.
    var activatesApp = true

    init(hotkeys: HotkeyService, settings: AppSettings, pluginSteps: @escaping () -> [OnboardingStep] = { [] }) {
        self.hotkeys = hotkeys
        self.settings = settings
        self.pluginSteps = pluginSteps
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// The active plugins' steps not completed yet, in plugin order.
    var pendingPluginSteps: [OnboardingStep] {
        let completed = Set(settings.completedOnboardingSteps)
        return pluginSteps().filter { !completed.contains($0.id) }
    }

    /// Whether launching should show onboarding at all.
    var hasPendingSteps: Bool {
        !settings.shortcutOnboardingCompleted || !pendingPluginSteps.isEmpty
    }

    /// Shows the first step that is still pending, if any.
    func showPendingSteps() {
        if !settings.shortcutOnboardingCompleted {
            showShortcutStep()
        } else if let step = pendingPluginSteps.first {
            showPluginStep(step)
        }
    }

    func showShortcutStep() {
        hotkeys.refreshDefault()
        currentPluginStep = nil
        let view = ShortcutStepView(
            hotkeys: hotkeys,
            onUse: { [weak self] in self?.finishShortcutStep(skipped: false) },
            onSkip: { [weak self] in self?.finishShortcutStep(skipped: true) }
        )
        present(AnyView(view))
    }

    func showPluginStep(_ step: OnboardingStep) {
        currentPluginStep = step.id
        let isLast = pendingPluginSteps.last?.id == step.id || pendingPluginSteps.isEmpty
        let view = PluginStepView(step: step, isLast: isLast) { [weak self] in
            self?.finishPluginStep()
        }
        present(AnyView(view))
    }

    /// Closing the window counts as skipping the step on screen.
    func windowWillClose(_ notification: Notification) {
        if !settings.shortcutOnboardingCompleted {
            settings.shortcutOnboardingCompleted = true
        }
        if let currentPluginStep {
            markCompleted(currentPluginStep)
        }
        currentPluginStep = nil
        window = nil
    }

    private func finishShortcutStep(skipped: Bool) {
        if skipped {
            hotkeys.resetToDefault()
        }
        settings.shortcutOnboardingCompleted = true
        showNextOrClose()
    }

    private func finishPluginStep() {
        if let currentPluginStep {
            markCompleted(currentPluginStep)
        }
        currentPluginStep = nil
        showNextOrClose()
    }

    private func showNextOrClose() {
        if let next = pendingPluginSteps.first {
            showPluginStep(next)
        } else {
            window?.close()
            window = nil
        }
    }

    private func markCompleted(_ id: String) {
        var completed = settings.completedOnboardingSteps
        guard !completed.contains(id) else { return }
        completed.append(id)
        settings.completedOnboardingSteps = completed
    }

    private func present(_ view: AnyView) {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        if let window {
            window.contentViewController = controller
            return
        }
        let window = ShellWindow(contentViewController: controller)
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
}

/// A plugin's onboarding step: its symbol and title, the plugin's view and "Continue" (or "Done").
struct PluginStepView: View {
    let step: OnboardingStep
    let isLast: Bool
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: step.symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(step.title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            step.makeView()
            HStack {
                Spacer()
                Button(action: onContinue) {
                    if isLast {
                        Text("Done", comment: "Onboarding button on the last step")
                    } else {
                        Text("Continue", comment: "Onboarding button that goes to the next step")
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
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
