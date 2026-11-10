import Foundation
import LintelKit

/// A command a strategy contributes to the plugin's catalogue (`LayoutStrategy.commands`): what the user sees and
/// binds in Settings, and the engine command it runs. A new kind's commands appear without a change anywhere else.
struct LayoutCommandSpec: Sendable {
    /// The command id (`windows.<...>`); it is a protected contract once shipped.
    var id: String
    var title: LocalizedStringResource
    var symbolName: String
    /// The family of numbered or directional commands that share one modifier row in Settings, if any; the
    /// command's default shortcut is the family's.
    var family: ShortcutFamily?
    /// The key of the command inside its family (its default shortcut is the family's modifiers and this key).
    var key: String?
    /// What the command asks the engine to do (the engine knows no verb: `EngineCommand.layout`).
    var command: EngineCommand
    var purpose: AccessibilityPurpose

    /// The shortcut the command has before the user records one.
    var defaultShortcut: KeyShortcut? {
        guard let family, let key else { return nil }
        return KeyShortcut(key: key, modifiers: family.defaultModifiers)
    }

    init(
        id: String, title: LocalizedStringResource, symbolName: String, family: ShortcutFamily? = nil,
        key: String? = nil, command: EngineCommand, purpose: AccessibilityPurpose = .moving
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.family = family
        self.key = key
        self.command = command
        self.purpose = purpose
    }
}

/// A row a strategy adds to Settings → Window Management → Basics for its own settings that are not options (for
/// Zones: the default layout of each display shape). The pane draws it, the strategy decides what it means.
struct LayoutSettingRow: Identifiable {
    struct Choice: Hashable {
        var id: String
        var title: String
    }

    var id: String
    var title: String
    var help: String?
    /// Read when the pane is drawn, so a library that changed shows its layouts.
    var choices: @MainActor () -> [Choice]
    var selection: @MainActor () -> String
    var select: @MainActor (String) -> Void
}

/// A strategy that has settings rows of its own (`LayoutSettingRow`). The registry's strategies are asked; a kind
/// that does not conform adds none.
@MainActor
protocol LayoutSettingsProviding {
    func settingRows(model: WindowsSettingsModel) -> [LayoutSettingRow]
}
