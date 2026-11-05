import Foundation
import SwiftUI

// Contract additions for the main window and the redesigned Settings (spec
// `.ai/specs/2026-11-04-lintel-main-window.md`, ADR 0008). All of them are additive: every contribution that uses
// them has an empty default, so a plugin written before them compiles unchanged.

/// A request to show one thing inside a workspace section, for example kind `openNote` with a note key.
public struct WorkspaceRoute: Hashable, Sendable {
    public let kind: String
    public let id: String

    public init(kind: String, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// A command shown in a menu or a command palette. Unlike `PluginCommand`, it has no global shortcut of its own:
/// `shortcut` is only the key equivalent shown next to the menu item.
public struct CommandInfo: Sendable {
    public let title: LocalizedStringResource
    public let shortcut: KeyShortcut?
    /// Menu validation and palette: a disabled command is shown greyed out.
    public let isEnabled: @MainActor @Sendable () -> Bool
    public let run: @MainActor @Sendable () -> Void

    public init(
        title: LocalizedStringResource,
        shortcut: KeyShortcut? = nil,
        isEnabled: @escaping @MainActor @Sendable () -> Bool = { true },
        run: @escaping @MainActor @Sendable () -> Void
    ) {
        self.title = title
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.run = run
    }
}

/// A section of the main window's Workspace mode (for example Notes). The section draws its left column and
/// content and owns its status bar; the shell owns the title bar.
public struct WorkspaceSection: Identifiable, Sendable {
    /// Stable, for example `notes`; stored in `app.mainWindow.section`.
    public let id: String
    public let title: LocalizedStringResource
    public let symbolName: String
    /// Order of the sections; lower comes first.
    public let order: Int
    public let makeView: @MainActor @Sendable () -> AnyView
    /// Shows what a route points at; `true` when the section handled it.
    public let handleRoute: @MainActor @Sendable (WorkspaceRoute) -> Bool
    /// Called before a mode switch or the window closes, so the section can flush what it holds.
    public let willHide: @MainActor @Sendable () async -> Void
    /// Command-W in Workspace mode: `true` when the section closed something itself (a tab); otherwise the
    /// window closes after `willHide`.
    public let handleClose: @MainActor @Sendable () -> Bool
    /// The section menu's items (new note, palette, hide content).
    public let menuItems: [CommandInfo]

    public init(
        id: String,
        title: LocalizedStringResource,
        symbolName: String,
        order: Int,
        makeView: @escaping @MainActor @Sendable () -> AnyView,
        handleRoute: @escaping @MainActor @Sendable (WorkspaceRoute) -> Bool = { _ in false },
        willHide: @escaping @MainActor @Sendable () async -> Void = {},
        handleClose: @escaping @MainActor @Sendable () -> Bool = { false },
        menuItems: [CommandInfo] = []
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.order = order
        self.makeView = makeView
        self.handleRoute = handleRoute
        self.willHide = willHide
        self.handleClose = handleClose
        self.menuItems = menuItems
    }
}

/// A button on a plugin's Settings banner. The shell runs it and then reads the status again.
public struct SettingsStatusAction: Sendable {
    public enum Destination: Sendable {
        /// Opens the Models pane, scrolled to the package's row when it is known.
        case models(packageID: String?)
        /// The permission's page in System Settings.
        case systemSettings(Permission)
        /// Turns the plugin on; on a `failed` plugin this runs activation again ("Try Again"), on an active
        /// plugin it does nothing.
        case enablePlugin
        /// An action inside the plugin itself (Try Again on a locked key, Start Indexing); never navigation.
        case plugin(id: String, perform: @MainActor @Sendable () async -> Void)
    }

    public let title: LocalizedStringResource
    public let destination: Destination

    public init(title: LocalizedStringResource, destination: Destination) {
        self.title = title
        self.destination = destination
    }
}

/// The banner of a plugin's Settings pane.
public struct SettingsStatus: Sendable {
    public enum Level: Hashable, Sendable {
        case ok
        case attention
        case error
        case neutral
    }

    public let level: Level
    public let title: LocalizedStringResource
    public let detail: LocalizedStringResource?
    /// At most two are shown (the shell ignores the rest); the first one is the primary button.
    public let fix: [SettingsStatusAction]
    /// Permissions the plugin works without on purpose (Files: Full Disk Access); the shell leaves them out
    /// when it compares the status with the permission states.
    public let acknowledgedPermissions: Set<Permission>

    public init(
        level: Level,
        title: LocalizedStringResource,
        detail: LocalizedStringResource? = nil,
        fix: [SettingsStatusAction] = [],
        acknowledgedPermissions: Set<Permission> = []
    ) {
        self.level = level
        self.title = title
        self.detail = detail
        self.fix = fix
        self.acknowledgedPermissions = acknowledgedPermissions
    }
}

/// The kind of a downloadable model. An open set: a new kind is a new static value.
public struct ModelKind: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let speech = ModelKind(rawValue: "speech")
    public static let llm = ModelKind(rawValue: "llm")
    public static let diarization = ModelKind(rawValue: "diarization")
}

/// One model a plugin uses, shown as a "used by" chip in the Models pane.
public struct ModelUsage: Sendable {
    /// The package id in the model catalog; an unknown id is ignored by the Models pane.
    public let packageID: String
    public let kind: ModelKind
    /// What the plugin uses it for, for example "Transcription".
    public let role: LocalizedStringResource
    public let isRequired: Bool
    public let isSelected: Bool
    /// "Choose Folder…": the plugin writes its own folder key. `nil` when the plugin offers no folder choice.
    public let chooseFolder: (@MainActor @Sendable (URL?) -> Void)?
    /// The folder the user chose for this model ("Choose Folder…"), which the plugin loads it from instead of the
    /// downloaded copy; `nil` when it uses the download. The Models pane shows that folder's state. Added after the
    /// main window shipped in PR #52 (owner decision); defaults to `nil`.
    public let customFolder: URL?
    /// The plugin's own "in use" check (a recording, a notes run, a loaded runtime).
    public let isInUse: @MainActor @Sendable () async -> Bool
    /// Holds off new work that needs the model while it is being removed; returns the release.
    public let reserveRemoval: @MainActor @Sendable () -> @MainActor @Sendable () -> Void

    public init(
        packageID: String,
        kind: ModelKind,
        role: LocalizedStringResource,
        isRequired: Bool,
        isSelected: Bool,
        chooseFolder: (@MainActor @Sendable (URL?) -> Void)? = nil,
        customFolder: URL? = nil,
        isInUse: @escaping @MainActor @Sendable () async -> Bool = { false },
        reserveRemoval: @escaping @MainActor @Sendable () -> @MainActor @Sendable () -> Void = { {} }
    ) {
        self.packageID = packageID
        self.kind = kind
        self.role = role
        self.isRequired = isRequired
        self.isSelected = isSelected
        self.chooseFolder = chooseFolder
        self.customFolder = customFolder
        self.isInUse = isInUse
        self.reserveRemoval = reserveRemoval
    }
}

/// The Settings sidebar group a plugin's pane is listed in. An open set: a new group is a new static value.
public struct SettingsGroup: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let lintel = SettingsGroup(rawValue: "lintel")
    public static let search = SettingsGroup(rawValue: "search")
    public static let voice = SettingsGroup(rawValue: "voice")
}

/// A question the shell asks before it runs a destructive `ResultAction` (for example "Press ⌃X again").
public struct ActionConfirmation: Sendable {
    public let prompt: LocalizedStringResource

    public init(prompt: LocalizedStringResource) {
        self.prompt = prompt
    }
}
