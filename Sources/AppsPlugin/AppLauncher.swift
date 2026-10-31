import Foundation
import PounceCore
import PounceKit

/// How Pounce opens an app: bring it to the front, add it to Recent Items, and hand activation to it
/// first, because the panel never activates Pounce (macOS cooperative activation).
enum AppLauncher {
    static func options(for record: AppRecord) -> ApplicationOpenOptions {
        ApplicationOpenOptions(
            activates: true,
            addsToRecentItems: true,
            promptsUserIfNeeded: true,
            yieldsActivationTo: record.bundleIdentifier
        )
    }
}

/// The actions of an app result: Return opens or activates it, Command-Return shows it in Finder.
struct AppActions: Sendable {
    static let openID = "apps.open"
    static let revealID = "apps.reveal"

    let record: AppRecord
    let itemKey: ItemKey
    let usage: any UsageRecorder
    let workspace: any WorkspaceClient
    let clock: @Sendable () -> Date

    var all: [ResultAction] { [open, reveal] }

    var open: ResultAction {
        let record = record
        let itemKey = itemKey
        let usage = usage
        let workspace = workspace
        let clock = clock
        return ResultAction(
            id: Self.openID,
            title: LocalizedStringResource("Open", comment: "Result action that opens the selected app"),
            symbolName: "arrow.up.forward.app",
            shortcut: KeyShortcut(key: "\r")
        ) { context in
            try await workspace.openApplication(at: record.url, options: AppLauncher.options(for: record))
            let prefix = context.query.flatMap { Ranker.queryPrefix($0.normalized) }
            try await usage.recordUse(of: itemKey, queryPrefix: prefix, at: clock())
        }
    }

    var reveal: ResultAction {
        let url = record.url
        let workspace = workspace
        return ResultAction(
            id: Self.revealID,
            title: LocalizedStringResource("Show in Finder", comment: "Result action that reveals the item in Finder"),
            symbolName: "folder",
            shortcut: KeyShortcut(key: "\r", modifiers: .command)
        ) { _ in
            await workspace.revealInFinder([url])
        }
    }
}
