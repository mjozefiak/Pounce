import LintelKit
import LintelPersistence
import LintelUI
import SwiftUI

/// A usage store that can forget everything at once: Settings → Advanced → "Reset Ranking".
nonisolated protocol RankingResettable: Sendable {
    func resetRanking() async throws
}

extension UsageRepository: RankingResettable {
    nonisolated func resetRanking() async throws {
        try await removeAllUsage()
    }
}

extension InMemoryUsageRecorder: RankingResettable {
    func resetRanking() async throws {
        removeEverything()
    }
}

/// What Settings → Advanced does (spec step 4.1), kept out of the view so it is tested.
struct AdvancedControls {
    enum ResetError: LocalizedError {
        case unsupported

        var errorDescription: String? {
            String(localized: "This ranking store cannot be reset.", comment: "Error when Reset Ranking is unavailable")
        }
    }

    let usage: any UsageRecorder
    /// Called after a successful reset, so an open panel searches again.
    let onReset: () -> Void
    /// "Show Again": the welcome flow from its first page (main window only).
    let showWelcome: () -> Void
    /// "About…": the About window (main window only).
    let showAbout: () -> Void
    /// The version shown under "About Lintel"; `nil` for an unbundled build.
    let version: String?

    init(
        usage: any UsageRecorder, showWelcome: @escaping () -> Void = {}, showAbout: @escaping () -> Void = {},
        version: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        onReset: @escaping () -> Void
    ) {
        self.usage = usage
        self.showWelcome = showWelcome
        self.showAbout = showAbout
        self.version = version
        self.onReset = onReset
    }

    /// "Version 1.0 · licences", or just "Licences" without a bundle version.
    var aboutDetail: String {
        guard let version else {
            return String(localized: "Licences", comment: "Settings → Advanced: About row detail")
        }
        return String(
            localized: "Version \(version) · licences",
            comment: "Settings → Advanced: About row detail with the version")
    }

    /// "Reset Ranking": forgets every use and query association of every plugin. Returns the error message
    /// to show, or `nil` when it worked.
    func resetRanking() async -> String? {
        guard let store = usage as? any RankingResettable else {
            return ResetError.unsupported.localizedDescription
        }
        do {
            try await store.resetRanking()
            onReset()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Settings → Advanced: Reset Ranking with a confirmation, and in the main window the Welcome and About rows
/// (prototype `set-advanced`). The old window keeps `LegacyAdvancedPane`.
struct AdvancedPane: View {
    let controls: AdvancedControls

    @Environment(\.settingsHostStyle) private var hostStyle

    static let confirmation = DestructiveConfirmation(
        prompt: LocalizedStringResource("Reset the ranking?", comment: "Reset Ranking confirmation title"),
        detail: LocalizedStringResource(
            "Results go back to the order of how well they match. This can’t be undone.",
            comment: "Reset Ranking confirmation message"),
        confirmTitle: LocalizedStringResource(
            "Reset Ranking", comment: "Confirmation button that clears the learned ranking"))

    var body: some View {
        if hostStyle == .legacyWindow {
            LegacyAdvancedPane(controls: controls)
        } else {
            AdvancedPaneContent(controls: controls)
        }
    }
}

extension View {
    /// The Reset Ranking confirmation, the result announcement and the failure alert, shared by both windows.
    func resetRankingFlow(
        controls: AdvancedControls, confirms: Binding<Bool>, done: Binding<Bool>, error: Binding<String?>
    ) -> some View {
        destructiveConfirmation(isPresented: confirms, AdvancedPane.confirmation) {
            Task {
                error.wrappedValue = await controls.resetRanking()
                done.wrappedValue = error.wrappedValue == nil
                if done.wrappedValue {
                    AccessibilityNotification.Announcement(
                        String(localized: "The ranking was reset.", comment: "Settings message after Reset Ranking")
                    ).post()
                }
            }
        }
        .alert(
            Text("The ranking could not be reset.", comment: "Alert title when Reset Ranking fails"),
            isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })
        ) {
            Button {
                error.wrappedValue = nil
            } label: {
                Text("OK", comment: "Button that dismisses an alert")
            }
        } message: {
            Text(error.wrappedValue ?? "")
        }
    }
}

/// The main window's Advanced pane: three rows in one card, no section header (the host titles the pane).
struct AdvancedPaneContent: View {
    let controls: AdvancedControls

    @Environment(\.lintelTextSize) private var textSize
    @State private var confirmsReset = false
    @State private var resetDone = false
    @State private var resetError: String?

    var body: some View {
        SettingsPane {
            Section {
                row(
                    title: Text("Reset Ranking", comment: "Settings → Advanced: label of the ranking reset"),
                    detail: Text(
                        "Forgets which results you open most.",
                        comment: "Settings → Advanced: explanation of Reset Ranking")
                ) {
                    Button {
                        confirmsReset = true
                    } label: {
                        Text("Reset Ranking…", comment: "Settings button that clears the learned ranking")
                    }
                    .lintelDestructiveButton()
                }
                row(
                    title: Text(
                        LocalizedStringResource(
                            "settings.advanced.welcome", defaultValue: "Welcome",
                            comment: "Settings → Advanced: label of the welcome row")),
                    detail: nil
                ) {
                    Button(action: controls.showWelcome) {
                        Text("Show Again", comment: "Settings → Advanced: button that shows the welcome flow again")
                    }
                }
                row(
                    title: Text("About Lintel", comment: "Settings → Advanced: label of the About row"),
                    detail: Text(controls.aboutDetail)
                ) {
                    Button(action: controls.showAbout) {
                        Text("About…", comment: "Settings → Advanced: button that opens the About window")
                    }
                }
                if resetDone {
                    Label {
                        Text("The ranking was reset.", comment: "Settings message after Reset Ranking")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .accessibilityHidden(true)
                    }
                    .font(textSize.font(.callout))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .resetRankingFlow(
            controls: controls, confirms: $confirmsReset, done: $resetDone, error: $resetError)
    }

    private func row<Action: View>(title: Text, detail: Text?, @ViewBuilder action: () -> Action) -> some View {
        LabeledContent {
            action()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                title.font(textSize.font(.body))
                if let detail {
                    detail
                        .font(textSize.font(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
