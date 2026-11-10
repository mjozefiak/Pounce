#if DEBUG
import AppKit
import Foundation
import LintelKit

/// DEBUG-only launch arguments that isolate a QA run from the user's real data (`docs/qa.md`).
/// Release builds compile this file out, so the arguments do nothing there.
///
/// Any `--qa…` argument turns QA mode on. In QA mode Lintel uses a temporary data root, in-memory
/// settings, an in-memory Keychain and a private named pasteboard, never registers global hotkeys and
/// never activates itself (windows are ordered front without taking keyboard focus from the tester).
struct QAOptions: Equatable {
    enum Appearance: String, Equatable {
        case light
        case dark

        var name: NSAppearance.Name {
            switch self {
            case .light: .aqua
            case .dark: .darkAqua
            }
        }
    }

    /// `--qa-data-root <path>`: data root instead of `~/Library/Application Support/Lintel`.
    /// Without it, QA mode creates a fresh temporary directory.
    var dataRoot: URL?
    /// `--qa-appearance light|dark`: forces the app's appearance without touching system settings.
    var appearance: Appearance?
    /// `--qa-show-menu`: opens the menu bar menu shortly after launch, for window-only screenshots.
    var showsMenu = false
    /// `--qa-quit-after <seconds>`: closes any open menu and quits after the delay.
    var quitAfter: Duration?
    /// `--qa-snapshot <path>`: before `--qa-quit-after` quits, writes the main window's content as a PNG. It renders
    /// the app's own views (`cacheDisplay`), so it needs no screen-recording permission.
    var snapshotPath: String?
    /// `--qa-setting <key>=<value>` (repeatable): seeds the in-memory settings. `true`/`false` become
    /// booleans, integers become integers, anything else a string.
    var settings: [String: SettingValue] = [:]
    /// `--qa-panel <mode>`: opens the panel after launch without the global hotkey. `search` is the
    /// search mode; any other value is a plugin's `PanelModeID`.
    var panelMode: String?
    /// `--qa-query <text>`: the query typed into the panel opened with `--qa-panel`.
    var query: String?
    /// `--qa-fail-action`: once the panel's results load, shows the failed-action message for the selected
    /// row's first action without running it (the state a moved or deleted app produces).
    var failsAction = false
    /// `--qa-confirm-action`: once the panel's results load, shows the "Press ⌃X again" confirmation of the
    /// selected row's first action that asks first, without running it and without the 5 s timeout.
    var confirmsAction = false
    /// `--qa-settings general|features|permissions|advanced|models|<plugin id>`: opens the main window's Settings
    /// mode on that pane.
    var settingsPane: String?
    /// `--qa-window workspace|settings`: opens the main window in that mode (spec `2026-11-04-lintel-main-window`,
    /// step 1.2). Workspace mode falls back to Settings while no workspace section is registered.
    var windowMode: MainWindowState.Mode?
    /// `--qa-onboarding`: shows the whole welcome screen (Phase 4), whatever was completed.
    var showsOnboarding = false
    /// `--qa-about`: shows the About window (Phase 4).
    var showsAbout = false
    /// `--qa-onboarding-step <step id>`: shows the welcome screen on one page: `intro`, `shortcut`, a
    /// plugin's step (for example `clipboard.intro`) or the final page `done`.
    var onboardingStep: String?
    /// `--qa-pasteboard-access allow|default|ask|deny`: the pasteboard access behaviour plugins see.
    var pasteboardAccess: PasteboardAccess?
    /// `--qa-accessibility granted|denied`: the Accessibility status plugins see. Without it the real
    /// status is read (never changed).
    var accessibility: PermissionStatus?
    /// `--qa-full-disk-access granted|denied`: the Full Disk Access status plugins see. QA mode never
    /// probes the real state; without the argument it is `denied`.
    var fullDiskAccess: PermissionStatus?
    /// `--qa-spotlight on|off`: pretends Spotlight does or does not hold Command-Space, instead of reading
    /// the system's symbolic hotkeys.
    var spotlightHoldsCommandSpace: Bool?
    /// `--qa-record-use <item key>` (repeatable): records a use in the QA ranking database before the
    /// panel opens, so the empty-query "recently used" list has content.
    var recordedUses: [String] = []
    /// `--qa-activity <bundleID>[=<uses>]` (repeatable): app activity written into the empty QA activity
    /// store before the panel opens, so the "Suggested" section has content (app suggestions).
    var appActivity: [String] = []
    /// `--qa-activity-live`: lets the real activity tracker and Spotlight seed run in QA mode.
    var liveAppActivity = false
    /// `--qa-notes`: the Notes section lists fixture notes (spec `2026-11-04-notes-workspace`, step 1.2). No store
    /// exists before step 4.0, so fixtures are all it can show.
    var notesFixtures = false
    /// `--qa-meeting-mic-wav <path>` / `--qa-meeting-system-wav <path>`: 16 kHz mono WAV files played back as
    /// the meeting's microphone and system tracks instead of real audio (meeting notes, step 1.5). Real
    /// capture is never started in QA mode.
    var meetingMicWAV: URL?
    var meetingSystemWAV: URL?
    /// `--qa-meeting-spool-dir <path>`: folder for the encrypted spool of QA meetings instead of
    /// `<data root>/Plugins/meetings/Spool`. The Keychain is the in-memory one in QA mode anyway.
    var meetingSpoolDirectory: URL?

    /// The file plugin's DEBUG-only fake home and its roots, which QA mode always sets
    /// (`AppEnvironment.qaFileIndexSettings`).
    static let filesHomeKey = "plugins.files.qaHome"
    static let filesRootsKey = "plugins.files.roots"
    /// The app plugin's DEBUG-only activity keys (`AppEnvironment.qaAppActivitySettings`).
    static let appsActivityKey = "plugins.apps.qaActivity"
    static let appsLiveActivityKey = "plugins.apps.qaLiveActivity"
    /// The Notes plugin's DEBUG-only fixtures key (`AppEnvironment.qaNotesSettings`).
    static let notesFixturesKey = "plugins.notes.qaFixtures"
    /// Settings that `--qa-setting` reads as comma-separated lists.
    static let listSettingKeys: Set<String> = [SettingsKeys.sectionOrder, "plugins.apps.suggestions.hidden"]

    enum ParseError: Error, Equatable {
        case missingValue(String)
        case invalidValue(String, String)
        case unknownArgument(String)
    }

    /// Returns `nil` when no `--qa…` argument is present.
    static func parse(_ arguments: [String]) throws(ParseError) -> QAOptions? {
        guard arguments.contains(where: { $0.hasPrefix("--qa") }) else { return nil }
        var options = QAOptions()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--qa") else { continue }
            switch argument {
            case "--qa":
                break
            case "--qa-data-root":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                options.dataRoot = URL(filePath: value, directoryHint: .isDirectory)
            case "--qa-appearance":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                guard let appearance = Appearance(rawValue: value) else {
                    throw .invalidValue(argument, value)
                }
                options.appearance = appearance
            case "--qa-show-menu":
                options.showsMenu = true
            case "--qa-quit-after":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                guard let seconds = Double(value), seconds > 0 else {
                    throw .invalidValue(argument, value)
                }
                options.quitAfter = .milliseconds(Int(seconds * 1000))
            case "--qa-snapshot":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                options.snapshotPath = value
            case "--qa-setting":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
                    throw .invalidValue(argument, value)
                }
                let key = String(value[..<separator])
                let text = String(value[value.index(after: separator)...])
                // A list setting takes comma-separated values.
                options.settings[key] =
                    Self.listSettingKeys.contains(key)
                    ? .stringArray(text.split(separator: ",").map(String.init)) : settingValue(text)
            case "--qa-panel":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                options.panelMode = value
            case "--qa-query":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                options.query = value
            case "--qa-settings":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                guard !value.isEmpty, !value.hasPrefix("-") else { throw .invalidValue(argument, value) }
                options.settingsPane = value
            case "--qa-window":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                guard let mode = MainWindowState.Mode(rawValue: value) else { throw .invalidValue(argument, value) }
                options.windowMode = mode
            case "--qa-onboarding":
                options.showsOnboarding = true
            case "--qa-about":
                options.showsAbout = true
            case "--qa-onboarding-step":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                options.onboardingStep = value
            case "--qa-pasteboard-access":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                switch value {
                case "allow": options.pasteboardAccess = .alwaysAllow
                case "default": options.pasteboardAccess = .systemDefault
                case "ask": options.pasteboardAccess = .ask
                case "deny": options.pasteboardAccess = .alwaysDeny
                default: throw .invalidValue(argument, value)
                }
            case "--qa-accessibility":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                switch value {
                case "granted": options.accessibility = .granted
                case "denied": options.accessibility = .denied
                default: throw .invalidValue(argument, value)
                }
            case "--qa-full-disk-access":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                switch value {
                case "granted": options.fullDiskAccess = .granted
                case "denied": options.fullDiskAccess = .denied
                default: throw .invalidValue(argument, value)
                }
            case "--qa-fail-action":
                options.failsAction = true
            case "--qa-confirm-action":
                options.confirmsAction = true
            case "--qa-spotlight":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                switch value {
                case "on": options.spotlightHoldsCommandSpace = true
                case "off": options.spotlightHoldsCommandSpace = false
                default: throw .invalidValue(argument, value)
                }
            case "--qa-record-use":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                guard ItemKey(rawValue: value) != nil else { throw .invalidValue(argument, value) }
                options.recordedUses.append(value)
            case "--qa-activity":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                guard Self.isActivityEntry(value) else { throw .invalidValue(argument, value) }
                options.appActivity.append(value)
            case "--qa-activity-live":
                options.liveAppActivity = true
            case "--qa-notes":
                options.notesFixtures = true
            case "--qa-meeting-mic-wav":
                options.meetingMicWAV = URL(filePath: try Self.pathValue(argument, iterator.next()))
            case "--qa-meeting-system-wav":
                options.meetingSystemWAV = URL(filePath: try Self.pathValue(argument, iterator.next()))
            case "--qa-meeting-spool-dir":
                options.meetingSpoolDirectory = URL(
                    filePath: try Self.pathValue(argument, iterator.next()), directoryHint: .isDirectory)
            default:
                throw .unknownArgument(argument)
            }
        }
        return options
    }

    private static func pathValue(_ argument: String, _ value: String?) throws(ParseError) -> String {
        guard let value else { throw .missingValue(argument) }
        guard !value.isEmpty, !value.hasPrefix("--") else { throw .invalidValue(argument, value) }
        return value
    }

    /// `<bundleID>` or `<bundleID>=<uses>` with a positive number of uses.
    static func isActivityEntry(_ value: String) -> Bool {
        let parts = value.split(separator: "=", omittingEmptySubsequences: false)
        guard let bundleID = parts.first, !bundleID.isEmpty, !bundleID.contains(","), !bundleID.hasPrefix("-"),
            parts.count <= 2
        else { return false }
        guard parts.count == 2 else { return true }
        return Int(parts[1]).map { $0 > 0 } ?? false
    }

    private static func settingValue(_ text: String) -> SettingValue {
        switch text {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return Int(text).map(SettingValue.integer) ?? .string(text)
        }
    }
}
#endif
