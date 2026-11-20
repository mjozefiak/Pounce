import Foundation
import LintelKit
import LintelProviders

/// The Settings → Meetings banner while notes are on (mockup v2, screens A2 and C-states). Pure: the model's
/// snapshot in, a `SettingsStatus` out; `nil` means "nothing of the provider to say" and the plugin's usual banner
/// applies. The actions are closures so the tests need no model.
struct ProviderBannerInput {
    var providerName: String
    var recipient: String
    var modelName: String
    var check: ProviderChoiceModel.Check
    var failure: ProviderJobFailure?
    var jobRunning: Bool
}

struct ProviderBannerActions {
    var useLocal: @MainActor @Sendable () async -> Void
    var install: @MainActor @Sendable () async -> Void
    var chooseFile: @MainActor @Sendable () async -> Void
    var checkAgain: @MainActor @Sendable () async -> Void
    var update: @MainActor @Sendable () async -> Void
    var updateLintel: @MainActor @Sendable () async -> Void
    var chooseModel: @MainActor @Sendable () async -> Void
    var writeOnThisMac: @MainActor @Sendable () async -> Void
    var retry: @MainActor @Sendable () async -> Void
}

enum ProviderStatusBanner {
    static let useLocalID = "provider.useLocal"

    static func status(_ input: ProviderBannerInput, actions: ProviderBannerActions) -> SettingsStatus {
        let name = input.providerName
        // What the check found about the CLI comes first: it is the newest information.
        if case .known(let status) = input.check {
            switch status {
            case .notInstalled: return notInstalled(name, actions)
            case .notSignedIn: return notSignedIn(name, actions)
            case .incompatibleVersion: return tooOld(actions)
            case .newerVersion: return tooNew(actions)
            case .ready: break
            }
        }
        if input.jobRunning, input.failure == nil {
            return SettingsStatus(
                level: .neutral,
                title: LocalizedStringResource(
                    "Writing notes with \(name)…", comment: "Settings → Meetings banner while a provider writes notes"),
                detail: LocalizedStringResource(
                    "Transcripts leave this Mac.", comment: "Settings → Meetings banner: the short notice"),
                fix: [useLocal(actions)])
        }
        if let failure = input.failure {
            return failed(failure.reason, input: input, actions: actions)
        }
        return SettingsStatus(
            level: .ok,
            title: LocalizedStringResource(
                "Ready · Notes are written by \(name).",
                comment: "Settings → Meetings banner when an external provider writes the notes"),
            detail: LocalizedStringResource(
                "Transcripts leave this Mac.", comment: "Settings → Meetings banner: the short notice"),
            fix: [useLocal(actions)])
    }

    private static func useLocal(_ actions: ProviderBannerActions) -> SettingsStatusAction {
        SettingsStatusAction(
            title: LocalizedStringResource(
                "Use Local", comment: "Settings → Meetings banner button: back to the built-in model"),
            destination: .plugin(id: useLocalID, perform: actions.useLocal))
    }

    private static func notInstalled(_ name: String, _ actions: ProviderBannerActions) -> SettingsStatus {
        SettingsStatus(
            level: .attention,
            title: LocalizedStringResource(
                "\(name) not found", comment: "Settings → Meetings banner: the provider's CLI is missing"),
            detail: LocalizedStringResource(
                "Lintel uses the \(name) installed on your Mac. New notes won’t be written until it is found.",
                comment: "Settings → Meetings banner detail: the provider's CLI is missing"),
            fix: [
                SettingsStatusAction(
                    title: LocalizedStringResource(
                        "How to Install", comment: "Settings → Meetings banner button: opens the install page"),
                    destination: .plugin(id: "provider.install", perform: actions.install)),
                SettingsStatusAction(
                    title: LocalizedStringResource(
                        "Choose File…", comment: "Settings → Meetings banner button: pick the CLI by hand"),
                    destination: .plugin(id: "provider.chooseFile", perform: actions.chooseFile)),
            ])
    }

    private static func notSignedIn(_ name: String, _ actions: ProviderBannerActions) -> SettingsStatus {
        SettingsStatus(
            level: .attention,
            title: LocalizedStringResource(
                "Sign in to \(name)", comment: "Settings → Meetings banner: the provider's CLI is not signed in"),
            detail: LocalizedStringResource(
                "Open Terminal and run the command below, then check again.",
                comment: "Settings → Meetings banner detail: how to sign in"),
            fix: [checkAgain(actions)])
    }

    private static func checkAgain(_ actions: ProviderBannerActions) -> SettingsStatusAction {
        SettingsStatusAction(
            title: LocalizedStringResource(
                "Check Again", comment: "Settings → Meetings banner button: look at the provider again"),
            destination: .plugin(id: "provider.checkAgain", perform: actions.checkAgain))
    }

    private static func tooOld(_ actions: ProviderBannerActions) -> SettingsStatus {
        SettingsStatus(
            level: .attention,
            title: LocalizedStringResource(
                "This Claude Code is too old",
                comment: "Settings → Meetings banner: the provider's CLI version is too old"),
            detail: LocalizedStringResource(
                "Update it, then check again.", comment: "Settings → Meetings banner detail: update the CLI"),
            fix: [
                SettingsStatusAction(
                    title: LocalizedStringResource(
                        "Update Claude Code", comment: "Settings → Meetings banner button: how to update the CLI"),
                    destination: .plugin(id: "provider.update", perform: actions.update)),
                checkAgain(actions),
            ])
    }

    private static func tooNew(_ actions: ProviderBannerActions) -> SettingsStatus {
        SettingsStatus(
            level: .attention,
            title: LocalizedStringResource(
                "This Claude Code is newer than this Lintel supports.",
                comment: "Settings → Meetings banner: the provider's CLI is newer than Lintel knows"),
            fix: [
                SettingsStatusAction(
                    title: LocalizedStringResource(
                        "Update Lintel", comment: "Settings → Meetings banner button: get a newer Lintel"),
                    destination: .plugin(id: "provider.updateLintel", perform: actions.updateLintel))
            ])
    }

    /// What a failed job says (screens 4, 5b and 6). Every one offers the built-in model for that meeting (D7=C);
    /// nothing is switched without a click.
    private static func failed(
        _ reason: ProviderJobFailure.Reason, input: ProviderBannerInput, actions: ProviderBannerActions
    ) -> SettingsStatus {
        let name = input.providerName
        let write = SettingsStatusAction(
            title: LocalizedStringResource(
                "Write on This Mac", comment: "Settings → Meetings banner button: the built-in model writes the notes"),
            destination: .plugin(id: "provider.writeOnThisMac", perform: actions.writeOnThisMac))
        let retry = SettingsStatusAction(
            title: LocalizedStringResource(
                "Try Again", comment: "Settings → Meetings banner button: the provider tries the notes again"),
            destination: .plugin(id: "provider.retry", perform: actions.retry))
        let weren = LocalizedStringResource(
            "Notes weren’t written", comment: "Settings → Meetings banner title: a provider job failed")
        switch reason {
        case .notInstalled: return notInstalled(name, actions)
        case .notSignedIn: return notSignedIn(name, actions)
        case .incompatibleVersion: return tooOld(actions)
        case .modelNotAvailable:
            let model = input.modelName
            return SettingsStatus(
                level: .error,
                title: LocalizedStringResource(
                    "\(model) isn’t available on your \(input.recipient == "Anthropic" ? "Claude" : name) plan",
                    comment: "Settings → Meetings banner title: the plan does not include the model"),
                detail: LocalizedStringResource(
                    "Choose another model. Nothing was written for the last meeting.",
                    comment: "Settings → Meetings banner detail: the plan does not include the model"),
                fix: [
                    SettingsStatusAction(
                        title: LocalizedStringResource(
                            "Choose Model", comment: "Settings → Meetings banner button: opens the model menu"),
                        destination: .plugin(id: "provider.chooseModel", perform: actions.chooseModel))
                ])
        case .tooLong:
            return SettingsStatus(
                level: .error,
                title: LocalizedStringResource(
                    "This meeting is too long for \(input.recipient == "Anthropic" ? "Claude" : name)",
                    comment: "Settings → Meetings banner title: the transcript needs more parts than allowed"),
                detail: LocalizedStringResource(
                    "Nothing was sent. The transcript is longer than Lintel can split safely.",
                    comment: "Settings → Meetings banner detail: transcript too long"),
                fix: [write])
        case .timedOut:
            return SettingsStatus(
                level: .error, title: weren,
                detail: LocalizedStringResource(
                    "Claude didn’t answer in time. Write them on this Mac instead? Nothing more is sent.",
                    comment: "Settings → Meetings banner detail: the provider timed out"),
                fix: [write, retry])
        case .network:
            return SettingsStatus(
                level: .error, title: weren,
                detail: LocalizedStringResource(
                    "Claude couldn’t be reached. Write them on this Mac instead? Nothing more is sent.",
                    comment: "Settings → Meetings banner detail: the provider could not be reached"),
                fix: [write, retry])
        case .rateLimited:
            return SettingsStatus(
                level: .error, title: weren,
                detail: LocalizedStringResource(
                    "Your Claude plan’s limit is reached. Write them on this Mac instead? Nothing more is sent.",
                    comment: "Settings → Meetings banner detail: the subscription limit is reached"),
                fix: [write, retry])
        case .other:
            return SettingsStatus(
                level: .error, title: weren,
                detail: LocalizedStringResource(
                    "Claude couldn’t write them. Write them on this Mac instead? Nothing more is sent.",
                    comment: "Settings → Meetings banner detail: the provider failed for another reason"),
                fix: [write, retry])
        }
    }
}
