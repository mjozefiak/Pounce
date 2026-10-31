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
    /// QA mode only: reports this access behaviour instead of the system's.
    let accessOverride: PasteboardAccess?

    init(name: NSPasteboard.Name? = nil, accessOverride: PasteboardAccess? = nil) {
        self.name = name
        self.accessOverride = accessOverride
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

    @MainActor func types() -> [String] {
        pasteboard.types?.map(\.rawValue) ?? []
    }

    /// Copies every representation of every item. Data the writer promised lazily is produced now, on
    /// the main actor (spike 2.2: `NSPasteboard` is not safe to read elsewhere).
    @MainActor func readContents(maxBytes: Int) -> PasteboardContents? {
        let pasteboard = pasteboard
        let changeCount = pasteboard.changeCount
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        var total = 0
        var copied: [PasteboardItem] = []
        for item in items {
            var representations: [PasteboardRepresentation] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                guard total <= maxBytes else {
                    return PasteboardContents(changeCount: changeCount, items: [], exceedsLimit: true)
                }
                representations.append(PasteboardRepresentation(type: type.rawValue, data: data))
            }
            copied.append(PasteboardItem(representations: representations))
        }
        return PasteboardContents(changeCount: changeCount, items: copied)
    }

    @MainActor @discardableResult func write(_ items: [PasteboardItem]) -> Int {
        let pasteboard = pasteboard
        pasteboard.clearContents()
        let objects = items.map { item in
            let object = NSPasteboardItem()
            for representation in item.representations {
                object.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return object
        }
        pasteboard.writeObjects(objects)
        return pasteboard.changeCount
    }

    @MainActor var accessBehavior: PasteboardAccess {
        if let accessOverride {
            return accessOverride
        }
        return Self.access(pasteboard.accessBehavior)
    }

    static func access(_ behavior: NSPasteboard.AccessBehavior) -> PasteboardAccess {
        switch behavior {
        case .alwaysAllow: .alwaysAllow
        case .alwaysDeny: .alwaysDeny
        case .ask: .ask
        case .default: .systemDefault
        @unknown default: .systemDefault
        }
    }
}

/// Posts Command-V through `CGEvent`. Phase 2 (spec step 2.5) refines the key code for non-QWERTY
/// layouts; Phase 0 only provides the port.
nonisolated struct SystemEventPoster: EventPoster {
    @MainActor func postPaste() throws(EventPosterError) {
        guard CGPreflightPostEventAccess() else { throw EventPosterError.notPermitted }
        guard !IsSecureEventInputEnabled() else { throw EventPosterError.secureEventInput }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = KeyboardLayout.pasteKeyCode()
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Finds the key that types "v" with Command in the current keyboard layout (spec step 2.5), so the
/// synthetic Command-V pastes on Dvorak, AZERTY and similar layouts. Layouts without a "v" (Cyrillic,
/// Greek…) use the ANSI V key, which apps match for Command shortcuts.
nonisolated enum KeyboardLayout {
    static let ansiV = CGKeyCode(kVK_ANSI_V)

    /// The first virtual key code (0–127) whose character, lowercased, is `character`.
    static func keyCode(producing character: String, translate: (CGKeyCode) -> String?) -> CGKeyCode? {
        (0..<128).lazy.map { CGKeyCode($0) }.first { translate($0)?.lowercased() == character }
    }

    /// Tries the layout with Command held (for "Dvorak – QWERTY ⌘"), then without, then the ANSI key.
    @MainActor static func pasteKeyCode() -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return ansiV }
        let layout = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let command = UInt32((cmdKey >> 8) & 0xFF)
        return keyCode(producing: "v") { translate(layout, keyCode: $0, modifiers: command) }
            ?? keyCode(producing: "v") { translate(layout, keyCode: $0, modifiers: 0) }
            ?? ansiV
    }

    static func translate(_ layout: Data, keyCode: CGKeyCode, modifiers: UInt32) -> String? {
        layout.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                base, UInt16(keyCode), UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
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

    @MainActor var frontmostApplication: RunningApplication? {
        NSWorkspace.shared.frontmostApplication.map(Self.running)
    }

    @MainActor func runningApplication(processIdentifier: pid_t) -> RunningApplication? {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
            !application.isTerminated
        else { return nil }
        return Self.running(application)
    }

    /// Fast user switching back to this session, and unlocking the screen (the login keychain may have
    /// been locked while the screen was).
    func sessionActivations() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let workspace = Task { @MainActor in
                for await _ in NSWorkspace.shared.notificationCenter.notifications(
                    named: NSWorkspace.sessionDidBecomeActiveNotification
                ) {
                    continuation.yield()
                }
            }
            let unlock = Task { @MainActor in
                for await _ in DistributedNotificationCenter.default().notifications(
                    named: Notification.Name("com.apple.screenIsUnlocked")
                ) {
                    continuation.yield()
                }
            }
            continuation.onTermination = { _ in
                workspace.cancel()
                unlock.cancel()
            }
        }
    }

    @MainActor static func running(_ application: NSRunningApplication) -> RunningApplication {
        RunningApplication(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            name: application.localizedName
        )
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
    /// QA mode only: reports this Accessibility status instead of the system's.
    let accessibilityOverride: PermissionStatus?

    init(pasteboardName: NSPasteboard.Name? = nil, accessibilityOverride: PermissionStatus? = nil) {
        self.pasteboardName = pasteboardName
        self.accessibilityOverride = accessibilityOverride
    }

    @MainActor func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            if let accessibilityOverride {
                return accessibilityOverride
            }
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

    func removeAll(pluginID: PluginID) async throws {
        uses = uses.filter { $0.key.pluginID != pluginID }
        for prefix in associations.keys {
            associations[prefix] = associations[prefix]?.filter { $0.key.pluginID != pluginID }
        }
    }
}
