#if DEBUG
import AppKit
import Foundation

/// DEBUG-only launch arguments that isolate a QA run from the user's real data (`docs/qa.md`).
/// Release builds compile this file out, so the arguments do nothing there.
///
/// Any `--qa…` argument turns QA mode on. In QA mode Pounce uses a temporary data root, a separate
/// `UserDefaults` suite, an in-memory Keychain and a private named pasteboard, and it never
/// registers global hotkeys.
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
            default:
                throw .unknownArgument(argument)
            }
        }
        return options
    }
}
#endif
