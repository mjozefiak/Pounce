import CoreFoundation
import Foundation
import LintelKit

/// What the Settings banner needs to know, gathered by `WindowsSettingsModel.refresh()` (the banner itself only
/// reads these values, so the shell can read it while a view draws).
struct WindowsStatusInputs: Equatable, Sendable {
    var trusted = true
    /// A window is parked right now (the engine's or the journal's).
    var hasParkedWindows = false
    var engineBanner: EngineBanner?
    /// `nil` while unknown: the key is an inference (ADR 0009, row 8), so an absent value shows no banner.
    var stageManagerOn: Bool?
    /// `true` when "Displays have separate Spaces" is off (`com.apple.spaces` `spans-displays`, ADR 0009 row 9).
    var displaysShareASpace: Bool?
    var stripEnabled = true
    var stripHasRoom: Bool?
    var workspaceCount = WindowsSettings.defaultWorkspaceCount
    /// The registered shortcuts that type a character on the active keyboard layout (`ShortcutSafety`).
    var unsafeShortcuts: [KeyShortcut] = []
}

/// The ids of the banner's own actions.
enum WindowsStatusAction {
    static let restoreWindows = "restoreWindows"
    static let openStageManager = "openStageManager"
    static let openSpaces = "openSpaces"
    static let startAgain = "startAgain"
    static let useControlOption = "useControlOption"
}

/// The banner of Settings → Window Management as a pure function (spec: UI/UX, "Banner states"). Priority:
/// error, then attention, then ok. A missing Accessibility permission answers `nil` when nothing worse is the
/// case, so the shell shows its own *Allow Accessibility* banner.
enum WindowsBanner {
    static func derive(
        _ inputs: WindowsStatusInputs, perform: @escaping @MainActor @Sendable (String) async -> Void
    ) -> SettingsStatus? {
        func plugin(_ id: String, _ title: LocalizedStringResource) -> SettingsStatusAction {
            SettingsStatusAction(title: title, destination: .plugin(id: id, perform: { await perform(id) }))
        }
        let openSettings = LocalizedStringResource(
            "Open System Settings", comment: "Settings banner button: opens System Settings")
        // Errors.
        if !inputs.trusted, inputs.hasParkedWindows {
            return SettingsStatus(
                level: .error,
                title: LocalizedStringResource(
                    "Windows are parked", comment: "Window HUD: windows are hidden and cannot be restored"),
                detail: LocalizedStringResource(
                    "Allow Accessibility to put them back.", comment: "Window HUD: what to do about parked windows"),
                fix: [
                    plugin(
                        WindowsStatusAction.restoreWindows,
                        LocalizedStringResource(
                            "Restore Windows", comment: "Settings banner button: puts every parked window back")),
                    SettingsStatusAction(title: openSettings, destination: .systemSettings(.accessibility)),
                ])
        }
        if inputs.engineBanner == .cannotJournal {
            return SettingsStatus(
                level: .error,
                title: LocalizedStringResource(
                    "Windows can't be hidden safely", comment: "Settings banner: the state file cannot be written"),
                detail: LocalizedStringResource(
                    "Lintel can't save its state, so no window is moved.",
                    comment: "Settings banner detail: the state file cannot be written"))
        }
        // Attention. Without Accessibility the shell's own banner says what to do.
        guard inputs.trusted else { return nil }
        if inputs.engineBanner == .watchdogTripped {
            return SettingsStatus(
                level: .attention,
                title: LocalizedStringResource(
                    "Window management stopped itself",
                    comment: "Settings banner: the engine froze after too many window changes"),
                detail: LocalizedStringResource(
                    "An app kept moving its windows. They were put back.",
                    comment: "Settings banner detail: the engine froze after too many window changes"),
                fix: [
                    plugin(
                        WindowsStatusAction.startAgain,
                        LocalizedStringResource("Start Again", comment: "Settings banner button: starts again"))
                ])
        }
        if inputs.stageManagerOn == true {
            return SettingsStatus(
                level: .attention,
                title: LocalizedStringResource("Stage Manager is on", comment: "Settings banner: Stage Manager is on"),
                detail: LocalizedStringResource(
                    "It moves windows itself. Turn it off for Window Management.",
                    comment: "Settings banner detail: Stage Manager is on"),
                fix: [plugin(WindowsStatusAction.openStageManager, openSettings)])
        }
        if inputs.displaysShareASpace == true {
            return SettingsStatus(
                level: .attention,
                title: LocalizedStringResource(
                    "Displays share one Space", comment: "Settings banner: displays do not have separate Spaces"),
                detail: LocalizedStringResource(
                    "Turn on “Displays have separate Spaces” in System Settings.",
                    comment: "Settings banner detail: displays do not have separate Spaces"),
                fix: [plugin(WindowsStatusAction.openSpaces, openSettings)])
        }
        // Registered shortcuts that type a letter take that letter away system-wide (Q3: registered anyway, so the
        // warning is visible here and one click away from fixed).
        if !inputs.unsafeShortcuts.isEmpty {
            return SettingsStatus(
                level: .attention,
                title: ShortcutWarning.title(count: inputs.unsafeShortcuts.count),
                detail: ShortcutWarning.detail(inputs.unsafeShortcuts),
                fix: [plugin(WindowsStatusAction.useControlOption, ShortcutWarning.action)])
        }
        if inputs.stripEnabled, inputs.stripHasRoom == false {
            return SettingsStatus(
                level: .attention,
                title: LocalizedStringResource(
                    "The menu bar has no room for the strip", comment: "Settings banner: the strip is not visible"),
                detail: LocalizedStringResource(
                    "Switch workspaces with the shortcuts or the launcher.",
                    comment: "Settings banner detail: the strip is not visible"))
        }
        return SettingsStatus(
            level: .ok,
            title: LocalizedStringResource(
                "Ready · \(inputs.workspaceCount) workspaces", comment: "Settings banner: Window Management works"))
    }
}

/// Reads the two system preferences the banner needs. The key names are inferences to be verified in the spike
/// (ADR 0009 rows 8 and 9); an absent value answers `nil`, which shows no banner.
struct SystemPreferences: Sendable {
    var readBool: @Sendable (_ domain: String, _ key: String) -> Bool?

    static let live = SystemPreferences { domain, key in
        guard let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    var stageManagerOn: Bool? { readBool("com.apple.WindowManager", "GloballyEnabled") }
    /// `spans-displays` true means the displays share one Space ("Displays have separate Spaces" is off).
    var displaysShareASpace: Bool? { readBool("com.apple.spaces", "spans-displays") }
}
