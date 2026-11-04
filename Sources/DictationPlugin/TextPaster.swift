import CoreGraphics
import Foundation
import LintelKit
import os

/// Puts dictated text into the app in front: through the pasteboard and a synthetic Command-V, like the
/// clipboard history does (spec: `TextPaster`).
///
/// - The text is written with the transient marker, so the clipboard history does not record it.
/// - The previous contents come back one second later, but only when that is safe: pasteboard access is
///   allowed, nothing on it is marked concealed/transient (a password manager's copy is left alone, since
///   writing again would stop its automatic clearing), it was read completely, and nobody copied anything
///   since the paste.
/// - Without Accessibility, under Secure Event Input, when the target is gone or is Lintel itself, the text
///   is only copied and nothing is restored.
@MainActor
final class TextPaster {
    enum Outcome: Equatable, Sendable {
        case pasted
        case copied(CopyReason)
    }

    enum CopyReason: Equatable, Sendable {
        case noAccessibility
        case secureEventInput
        case targetGone
        /// Lintel is in front (Settings, the "Try it" box): the text goes to the pasteboard only.
        case ownApp
    }

    /// How long the previous contents wait before they are put back.
    static let restoreDelay: Duration = .seconds(1)
    /// How long to wait for the shortcut's modifier keys to be released before pasting anyway.
    static let modifierTimeout: Duration = .milliseconds(500)
    private static let modifierPoll: Duration = .milliseconds(20)

    private let pasteboard: any PasteboardClient
    private let events: any EventPoster
    private let workspace: any WorkspaceClient
    private let permissions: any PermissionsReader
    private let clock: any Clock<Duration>
    private let restoresClipboard: () -> Bool
    private let ownBundleID: String?
    private let modifiersHeld: () -> Bool
    private let logger: Logger

    /// The scheduled restore of the last paste, for tests to wait on.
    private(set) var pendingRestore: Task<Void, Never>?

    init(
        pasteboard: any PasteboardClient,
        events: any EventPoster,
        workspace: any WorkspaceClient,
        permissions: any PermissionsReader,
        clock: any Clock<Duration>,
        restoresClipboard: @escaping () -> Bool,
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        modifiersHeld: @escaping () -> Bool = TextPaster.systemModifiersHeld,
        logger: Logger
    ) {
        self.pasteboard = pasteboard
        self.events = events
        self.workspace = workspace
        self.permissions = permissions
        self.clock = clock
        self.restoresClipboard = restoresClipboard
        self.ownBundleID = ownBundleID
        self.modifiersHeld = modifiersHeld
        self.logger = logger
    }

    nonisolated static func systemModifiersHeld() -> Bool {
        let flags = CGEventSource.flagsState(.hidSystemState)
        return !flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]).isEmpty
    }

    /// Writes `text` to the pasteboard and pastes it into the app in front now.
    @discardableResult
    func paste(_ text: String) async -> Outcome {
        let target = workspace.frontmostApplication
        let reason = copyOnlyReason(target: target)
        let snapshot = reason == nil && restoresClipboard() ? readPreviousContents() : nil

        let written = pasteboard.write([Self.item(for: text)])
        if let reason { return .copied(reason) }
        guard let target else { return .copied(.targetGone) }

        await waitForModifiers()
        guard workspace.runningApplication(processIdentifier: target.processIdentifier) != nil else {
            return .copied(.targetGone)
        }
        do {
            try events.postPaste()
        } catch .secureEventInput {
            return .copied(.secureEventInput)
        } catch {
            // `.notPermitted`, or nothing else the poster can throw.
            return .copied(.noAccessibility)
        }
        if let snapshot {
            scheduleRestore(snapshot, expecting: written)
        }
        return .pasted
    }

    private func copyOnlyReason(target: RunningApplication?) -> CopyReason? {
        guard permissions.status(of: .accessibility) == .granted else { return .noAccessibility }
        guard let target else { return .targetGone }
        if let ownBundleID, target.bundleIdentifier == ownBundleID { return .ownApp }
        return nil
    }

    private static func item(for text: String) -> PasteboardItem {
        PasteboardItem(representations: [
            PasteboardRepresentation(type: PasteboardRepresentation.plainTextType, data: Data(text.utf8)),
            PasteboardRepresentation(type: PasteboardRepresentation.transientMarkerType, data: Data()),
        ])
    }

    // MARK: Waiting for the shortcut's keys

    private func waitForModifiers() async {
        var waited: Duration = .zero
        while modifiersHeld(), waited < Self.modifierTimeout {
            try? await clock.sleep(for: Self.modifierPoll)
            waited += Self.modifierPoll
        }
    }

    // MARK: Restoring the clipboard

    private func readPreviousContents() -> [PasteboardItem]? {
        guard pasteboard.accessBehavior == .alwaysAllow else { return nil }
        let types = pasteboard.types()
        // A password manager's copy, a transient or auto-generated one: do not read it and do not restore it.
        guard types.allSatisfy({ !PasteboardRepresentation.markerTypes.contains($0) }) else { return nil }
        let maximum = 20 << 20
        guard let contents = pasteboard.readContents(maxBytes: maximum, including: { _ in true }) else {
            return nil
        }
        guard !contents.exceedsLimit, contents.changeCount == pasteboard.changeCount else { return nil }
        // `readContents` silently skips a type it cannot read, so compare each item's types with what was read
        // (dynamic types are not readable data and are left out of the comparison).
        let expected = pasteboard.itemTypes().map { Set($0.filter { !$0.hasPrefix("dyn.") }) }
        let read = contents.items.map { Set($0.types.filter { !$0.hasPrefix("dyn.") }) }
        guard !expected.isEmpty, expected == read else { return nil }
        return contents.items
    }

    private func scheduleRestore(_ items: [PasteboardItem], expecting written: Int) {
        let pasteboard = pasteboard
        let clock = clock
        let logger = logger
        pendingRestore = Task { @MainActor in
            try? await clock.sleep(for: Self.restoreDelay)
            guard !Task.isCancelled, pasteboard.changeCount == written else {
                logger.info("The pasteboard changed after the paste; not restoring it")
                return
            }
            // The restored write is marked transient too, so the clipboard history does not take it again.
            var restored = items
            if let first = restored.first {
                restored[0] = PasteboardItem(
                    representations: first.representations + [
                        PasteboardRepresentation(type: PasteboardRepresentation.transientMarkerType, data: Data())
                    ])
            }
            pasteboard.write(restored)
        }
    }
}
