import PounceKit
import PouncePersistence
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

/// Settings → Advanced: "Reset Ranking…" with a confirmation.
struct AdvancedPane: View {
    let controls: AdvancedControls

    @State private var confirmsReset = false
    @State private var resetDone = false
    @State private var resetError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button {
                        confirmsReset = true
                    } label: {
                        Text("Reset Ranking…", comment: "Settings button that clears the learned ranking")
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ranking", comment: "Settings label of the ranking reset")
                        Text(
                            "Pounce moves the results you pick often to the top. Resetting forgets what it learned; your apps, files and clipboard history stay.",
                            comment: "Settings explanation of Reset Ranking"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if resetDone {
                    Label {
                        Text("The ranking was reset.", comment: "Settings message after Reset Ranking")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .accessibilityHidden(true)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Advanced", comment: "Settings section title")
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog(
            Text("Reset the ranking?", comment: "Reset Ranking confirmation title"),
            isPresented: $confirmsReset
        ) {
            Button(role: .destructive) {
                Task {
                    resetError = await controls.resetRanking()
                    resetDone = resetError == nil
                    if resetDone {
                        AccessibilityNotification.Announcement(
                            String(localized: "The ranking was reset.", comment: "Settings message after Reset Ranking")
                        ).post()
                    }
                }
            } label: {
                Text("Reset Ranking", comment: "Confirmation button that clears the learned ranking")
            }
        } message: {
            Text(
                "Results go back to the order of how well they match. It cannot be undone.",
                comment: "Reset Ranking confirmation message"
            )
        }
        .alert(
            Text("The ranking could not be reset.", comment: "Alert title when Reset Ranking fails"),
            isPresented: Binding(get: { resetError != nil }, set: { if !$0 { resetError = nil } })
        ) {
            Button {
                resetError = nil
            } label: {
                Text("OK", comment: "Button that dismisses an alert")
            }
        } message: {
            Text(resetError ?? "")
        }
    }
}
