#if DEBUG
import AppKit
import Foundation
import PounceKit

/// DEBUG-only launch arguments that isolate a QA run from the user's real data (`docs/qa.md`).
/// Release builds compile this file out, so the arguments do nothing there.
///
/// Any `--qa…` argument turns QA mode on. In QA mode Pounce uses a temporary data root, in-memory
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

    /// `--qa-data-root <path>`: data root instead of `~/Library/Application Support/Pounce`.
    /// Without it, QA mode creates a fresh temporary directory.
    var dataRoot: URL?
    /// `--qa-appearance light|dark`: forces the app's appearance without touching system settings.
    var appearance: Appearance?
    /// `--qa-show-menu`: opens the menu bar menu shortly after launch, for window-only screenshots.
    var showsMenu = false
    /// `--qa-quit-after <seconds>`: closes any open menu and quits after the delay.
    var quitAfter: Duration?
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
    /// `--qa-settings general|features|<plugin id>`: opens the Settings window on that pane.
    var settingsPane: String?
    /// `--qa-onboarding`: shows the whole welcome screen (Phase 4), whatever was completed.
    var showsOnboarding = false
    /// `--qa-about`: shows the About window (Phase 4).
    var showsAbout = false
    /// `--qa-onboarding-step <step id>`: shows the welcome screen on one page: `intro`, `shortcut` or a
    /// plugin's step (for example `clipboard.intro`).
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

    /// The file plugin's DEBUG-only fake home and its roots, which QA mode always sets
    /// (`AppEnvironment.qaFileIndexSettings`).
    static let filesHomeKey = "plugins.files.qaHome"
    static let filesRootsKey = "plugins.files.roots"

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
            case "--qa-setting":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
                    throw .invalidValue(argument, value)
                }
                let key = String(value[..<separator])
                let text = String(value[value.index(after: separator)...])
                // A list setting takes comma-separated values.
                options.settings[key] =
                    key == SettingsKeys.sectionOrder
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
            default:
                throw .unknownArgument(argument)
            }
        }
        return options
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
