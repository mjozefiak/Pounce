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
    /// `--qa-settings general|features`: opens the Settings window on that pane.
    var settingsPane: String?
    /// `--qa-onboarding`: shows the first-launch Shortcut step.
    var showsOnboarding = false
    /// `--qa-spotlight on|off`: pretends Spotlight does or does not hold Command-Space, instead of reading
    /// the system's symbolic hotkeys.
    var spotlightHoldsCommandSpace: Bool?
    /// `--qa-record-use <item key>` (repeatable): records a use in the QA ranking database before the
    /// panel opens, so the empty-query "recently used" list has content.
    var recordedUses: [String] = []

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
                options.settings[key] = settingValue(String(value[value.index(after: separator)...]))
            case "--qa-panel":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                options.panelMode = value
            case "--qa-query":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                options.query = value
            case "--qa-settings":
                guard let value = iterator.next() else { throw .missingValue(argument) }
                guard ["general", "features"].contains(value) else { throw .invalidValue(argument, value) }
                options.settingsPane = value
            case "--qa-onboarding":
                options.showsOnboarding = true
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
