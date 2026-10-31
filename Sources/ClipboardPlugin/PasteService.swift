import Foundation
import PounceKit
import os

/// Which way Return goes for a chosen entry (spec step 2.5).
enum PasteDecision: Equatable, Sendable {
    case paste
    case copyOnly(CopyReason)

    enum CopyReason: Equatable, Sendable {
        /// Accessibility is not granted (or was lost with an update), so Command-V cannot be posted.
        case noAccessibility
        /// The app that was frontmost before the panel opened has quit.
        case targetGone
        /// Secure Event Input is on (a password field, Terminal's Secure Keyboard Entry), so the
        /// keystroke would not arrive.
        case secureEventInput
        /// The user asked to copy only (Command-Return).
        case requested
    }

    static func decide(accessibilityGranted: Bool, targetRunning: Bool) -> PasteDecision {
        guard accessibilityGranted else { return .copyOnly(.noAccessibility) }
        guard targetRunning else { return .copyOnly(.targetGone) }
        return .paste
    }

    /// The confirmation shown when the entry was only copied.
    var message: LocalizedStringResource? {
        switch self {
        case .paste:
            nil
        case .copyOnly(.noAccessibility):
            LocalizedStringResource(
                "Copied. Allow Accessibility to paste.",
                comment: "Confirmation after Return copied a clipboard entry because Accessibility is missing")
        case .copyOnly:
            LocalizedStringResource("Copied", comment: "Confirmation after a clipboard entry was copied")
        }
    }
}

/// Puts a history entry back on the pasteboard and, when it can, pastes it into the previous app with
/// a synthetic Command-V (`EventPoster`). Without Accessibility, under Secure Event Input or when the
/// previous app is gone, the entry stays on the pasteboard and the user sees "Copied".
///
/// Pounce's own write is reported to the watcher so it is not recorded again; the entry only moves to
/// the top and counts one more use.
@MainActor
final class PasteService {
    /// The panel fades out in 120 ms; the keystroke goes after it so the previous app has key focus.
    static let pasteDelay: Duration = .milliseconds(200)

    private let pasteboard: any PasteboardClient
    private let events: any EventPoster
    private let workspace: any WorkspaceClient
    private let permissions: any PermissionsReader
    private let clock: any Clock<Duration>
    private let now: () -> Date
    private let logger: Logger
    private let store: () -> ClipStore?
    private let ownWrite: (Int) -> Void
    private let changed: @Sendable () -> Void

    init(
        pasteboard: any PasteboardClient,
        events: any EventPoster,
        workspace: any WorkspaceClient,
        permissions: any PermissionsReader,
        clock: any Clock<Duration>,
        now: @escaping () -> Date = { Date() },
        logger: Logger,
        store: @escaping () -> ClipStore?,
        ownWrite: @escaping (Int) -> Void,
        changed: @escaping @Sendable () -> Void
    ) {
        self.pasteboard = pasteboard
        self.events = events
        self.workspace = workspace
        self.permissions = permissions
        self.clock = clock
        self.now = now
        self.logger = logger
        self.store = store
        self.ownWrite = ownWrite
        self.changed = changed
    }

    /// Return: paste when possible, otherwise copy. Returns what happened.
    @discardableResult
    func paste(_ id: Int64, context: ActionContext) async throws -> PasteDecision {
        try await write(id)
        let targetRunning = context.previousApp.flatMap { workspace.runningApplication(processIdentifier: $0) } != nil
        var decision = PasteDecision.decide(
            accessibilityGranted: permissions.status(of: .accessibility) == .granted,
            targetRunning: targetRunning
        )
        if decision == .paste {
            try? await clock.sleep(for: Self.pasteDelay)
            do {
                try events.postPaste()
            } catch .secureEventInput {
                decision = .copyOnly(.secureEventInput)
            } catch .notPermitted {
                decision = .copyOnly(.noAccessibility)
            }
        }
        if let message = decision.message {
            context.panel.showConfirmation(message)
        }
        return decision
    }

    /// Command-Return: copy only.
    func copy(_ id: Int64, context: ActionContext) async throws {
        try await write(id)
        if let message = PasteDecision.copyOnly(.requested).message {
            context.panel.showConfirmation(message)
        }
    }

    /// Loads the entry off the main actor, writes it to the pasteboard and records the use.
    private func write(_ id: Int64) async throws {
        guard let store = store() else { throw ClipboardError.historyUnavailable }
        let detail = try await Task.detached(priority: .userInitiated) { try store.detail(id) }.value
        guard let detail, !detail.items.isEmpty else { throw ClipboardError.entryGone }
        let changeCount = pasteboard.write(detail.items)
        ownWrite(changeCount)
        let date = now()
        let logger = logger
        let changed = changed
        Task.detached(priority: .utility) {
            do {
                try store.markUsed(id, at: date)
                changed()
            } catch {
                logger.error("Cannot record a clipboard use: \(String(describing: error), privacy: .private)")
            }
        }
    }
}

enum ClipboardError: Error, Sendable {
    case historyUnavailable
    case entryGone
}
