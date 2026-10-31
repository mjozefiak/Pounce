import Foundation
import Observation
import PounceKit
import Synchronization

/// Whether the history can be read and recorded right now.
enum HistoryAvailability: Equatable, Sendable {
    /// The plugin is not active.
    case inactive
    case ready
    /// The Keychain is locked; retried when the session becomes active and when the mode opens.
    case keychainLocked
    /// Access to the key was denied, or the Keychain reported another error. Nothing was deleted.
    case keychainUnavailable
}

/// The plugin's user-visible state, observed by its views (status banners, settings, onboarding).
@MainActor @Observable
final class ClipboardState {
    var availability: HistoryAvailability = .inactive
    var isPaused = false
    var access: PasteboardAccess = .alwaysAllow
    /// Accessibility is granted, so Return pastes; otherwise it copies.
    var pasteAllowed = false
    /// The key was missing and the history was archived and started again; shown until dismissed.
    var historyWasReset = false
    /// Number of entries, refreshed after changes (settings pane).
    var entryCount = 0

    /// Whether the watcher may run (`PasteboardAccess.ask` would prompt on every read, `.alwaysDeny`
    /// fails every read).
    var accessAllowsRecording: Bool {
        access == .alwaysAllow || access == .systemDefault
    }

    var isRecording: Bool {
        availability == .ready && !isPaused && accessAllowsRecording
    }
}

/// What the search source, running off the main actor, needs from the plugin: the open store and
/// whether Return pastes.
final class ClipboardShared: Sendable {
    private let store = Mutex<ClipStore?>(nil)
    private let pastes = Mutex(false)

    var current: ClipStore? { store.withLock { $0 } }
    var pasteAllowed: Bool { pastes.withLock { $0 } }

    func set(_ value: ClipStore?) {
        store.withLock { $0 = value }
    }

    func setPasteAllowed(_ value: Bool) {
        pastes.withLock { $0 = value }
    }
}

/// How an entry reads in the list: a one-line title, the source app and the time.
enum ClipPresentation {
    static let titleLength = 200

    static func title(_ summary: ClipSummary) -> String {
        switch summary.kind {
        case .image:
            let size = summary.previewText
            let image = String(localized: ClipKind.image.title)
            return size.isEmpty ? image : "\(image) \(size)"
        case .file:
            let names = summary.previewText.split(separator: "\n").map { URL(filePath: String($0)).lastPathComponent }
            return names.joined(separator: ", ")
        case .text, .rich, .url:
            let line =
                summary.previewText.split(whereSeparator: \.isNewline)
                .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            let collapsed = line.replacingOccurrences(of: "\t", with: " ")
            return String(collapsed.prefix(titleLength))
        }
    }

    /// "Safari · 5 min ago", or just the time when the source app is unknown.
    static func subtitle(_ summary: ClipSummary, now: Date) -> String {
        let time = relativeTime(summary.lastUsedAt, now: now)
        guard let app = summary.sourceAppName, !app.isEmpty else { return time }
        return "\(app) · \(time)"
    }

    static func relativeTime(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func icon(_ summary: ClipSummary) -> PounceKit.IconRef {
        if let bundleID = summary.sourceBundleID, !bundleID.isEmpty {
            return .bundleIdentifier(bundleID)
        }
        return .symbol(summary.kind.symbolName)
    }

    static func itemKey(_ id: Int64) -> ItemKey {
        ItemKey(pluginID: ClipboardPlugin.manifest.id, key: String(id))
    }

    static func entryID(_ key: ItemKey) -> Int64? {
        key.pluginID == ClipboardPlugin.manifest.id ? Int64(key.key) : nil
    }
}
