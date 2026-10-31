import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import PounceKit

/// Reads and writes one `NSPasteboard`: the general pasteboard normally, a named private pasteboard in
/// QA mode and tests, so the user's real clipboard is never read or replaced there.
nonisolated struct SystemPasteboardClient: PasteboardClient {
    /// `nil` means `NSPasteboard.general`.
    let name: NSPasteboard.Name?

    init(name: NSPasteboard.Name? = nil) {
        self.name = name
    }

    @MainActor private var pasteboard: NSPasteboard {
        name.map { NSPasteboard(name: $0) } ?? .general
    }

    @MainActor var changeCount: Int { pasteboard.changeCount }

    @MainActor func string() -> String? {
        pasteboard.string(forType: .string)
    }

    @MainActor @discardableResult func setString(_ string: String) -> Int {
        let pasteboard = pasteboard
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        return pasteboard.changeCount
    }
}

/// Posts Command-V through `CGEvent`. Phase 2 (spec step 2.5) refines the key code for non-QWERTY
/// layouts; Phase 0 only provides the port.
nonisolated struct SystemEventPoster: EventPoster {
    @MainActor func postPaste() throws(EventPosterError) {
        guard CGPreflightPostEventAccess() else { throw EventPosterError.notPermitted }
        guard !IsSecureEventInputEnabled() else { throw EventPosterError.secureEventInput }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

nonisolated struct SystemWorkspaceClient: WorkspaceClient {
    @MainActor var frontmostApplicationPID: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    @MainActor func open(_ url: URL) async throws {
        _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }

    @MainActor func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Hands activation to the app first: Pounce is never active, so under cooperative activation the
    /// opened app could otherwise stay behind the previous one.
    @MainActor func openApplication(at url: URL, options: ApplicationOpenOptions) async throws {
        if let bundleIdentifier = options.yieldsActivationTo {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleIdentifier)
        }
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: Self.configuration(for: options))
    }

    static func configuration(for options: ApplicationOpenOptions) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = options.activates
        configuration.addsToRecentItems = options.addsToRecentItems
        configuration.promptsUserIfNeeded = options.promptsUserIfNeeded
        return configuration
    }
}

/// Preflight-only permission checks; none of these trigger a TCC prompt.
nonisolated struct SystemPermissionsReader: PermissionsReader {
    /// The pasteboard whose access behaviour is reported (`nil` means the general pasteboard).
    let pasteboardName: NSPasteboard.Name?

    init(pasteboardName: NSPasteboard.Name? = nil) {
        self.pasteboardName = pasteboardName
    }

    @MainActor func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            return CGPreflightPostEventAccess() ? .granted : .denied
        case .fullDiskAccess:
            // Detected in Phase 3 by reading a protected path; unknown until then.
            return .notDetermined
        case .pasteboard:
            let pasteboard = pasteboardName.map { NSPasteboard(name: $0) } ?? .general
            switch pasteboard.accessBehavior {
            case .alwaysAllow:
                return .granted
            case .alwaysDeny:
                return .denied
            default:
                return .notDetermined
            }
        }
    }
}

/// Usage kept in memory: the fallback when `ranking.sqlite` cannot be opened, and a test double.
actor InMemoryUsageRecorder: UsageRecorder {
    private var uses: [ItemKey: (count: Int, last: Date)] = [:]
    private var associations: [String: [ItemKey: Int]] = [:]

    init() {}

    func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws {
        let current = uses[key]
        uses[key] = ((current?.count ?? 0) + 1, date)
        if let queryPrefix, !queryPrefix.isEmpty {
            associations[queryPrefix, default: [:]][key, default: 0] += 1
        }
    }

    func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] {
        var result: [ItemKey: UsageStats] = [:]
        for key in keys {
            guard let use = uses[key] else { continue }
            let associated = queryPrefix.flatMap { associations[$0]?[key] } ?? 0
            result[key] = UsageStats(
                frecency: Double(use.count),
                lastUsedAt: use.last,
                useCount: use.count,
                queryAssociationCount: associated
            )
        }
        return result
    }

    func mostUsed(pluginID: PluginID, limit: Int, now: Date) async throws -> [ItemKey] {
        uses.filter { $0.key.pluginID == pluginID }
            .sorted {
                $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key.rawValue < $1.key.rawValue
            }
            .prefix(max(0, limit))
            .map(\.key)
    }
}
