import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// Phase 0, step 0.5: the warning about shortcuts that type a character is a banner at the top of the pane (not a note
/// in the collapsed Advanced), with a one-click fix that changes only the flagged commands.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ShortcutWarningTests {
    /// What a Polish programmers' layout types with ⌥ (and ⇧) for the keys the plugin binds: ⌥1, ⌥4, ⌥5, ⌥9,
    /// ⌥H, ⌥K, ⌥L and the shifted keys. ⌥-, ⌥=, ⌥/ and ⌥Tab type nothing.
    static let polish: ShortcutSafety.KeyTranslation = { code, modifiers in
        guard modifiers.contains(.option), !modifiers.contains(.control), !modifiers.contains(.command) else {
            return nil
        }
        let letters: [UInt16: String] = [
            18: "ą", 21: "ś", 23: "ć", 25: "ź", 4: "ę", 40: "ń", 37: "ł", 19: "ę", 20: "ó", 22: "ż", 26: "ń",
        ]
        return letters[code]
    }

    private func status(_ build: (inout WindowsStatusInputs) -> Void) -> SettingsStatus? {
        var inputs = WindowsStatusInputs()
        build(&inputs)
        return WindowsBanner.derive(inputs) { _ in }
    }

    private func title(_ status: SettingsStatus?) -> String { status.map { String(localized: $0.title) } ?? "nil" }

    private let keys = [
        KeyShortcut(key: "k", modifiers: [.option]), KeyShortcut(key: "1", modifiers: [.option]),
        KeyShortcut(key: "l", modifiers: [.option]), KeyShortcut(key: "h", modifiers: [.option, .shift]),
        KeyShortcut(key: "9", modifiers: [.option]),
    ]

    // MARK: The banner table

    @Test func shortcutsThatTypeLettersMakeAnAttentionBannerWithOneAction() throws {
        let banner = try #require(status { $0.unsafeShortcuts = keys })
        #expect(banner.level == .attention)
        #expect(String(localized: banner.title).contains("5"))
        #expect(banner.fix.count == 1)
        #expect(String(localized: try #require(banner.fix.first).title) == "Use ⌃⌥ for these")
        // Names the first three and counts the rest.
        let detail = String(localized: try #require(banner.detail))
        #expect(detail.contains("⌥K, ⌥L, ⌥⇧H"))
        #expect(detail.contains("2"))
        #expect(!detail.contains("⌥9"))
    }

    @Test func theWarningStaysOffWhenNothingTypesAndTheBannerIsReadyAgain() {
        #expect(status { $0.unsafeShortcuts = [] }?.level == .ok)
    }

    @Test func theWarningRanksBelowErrorsAndTheEngineProblemsButAboveTheStripAndReady() {
        let some = keys
        #expect(
            status {
                $0.unsafeShortcuts = some
                $0.engineBanner = .cannotJournal
            }?.level == .error)
        #expect(
            title(
                status {
                    $0.unsafeShortcuts = some
                    $0.engineBanner = .watchdogTripped
                }) == "Window management stopped itself")
        #expect(
            title(
                status {
                    $0.unsafeShortcuts = some
                    $0.stageManagerOn = true
                }) == "Stage Manager is on")
        #expect(
            title(
                status {
                    $0.unsafeShortcuts = some
                    $0.displaysShareASpace = true
                }) == "Displays share one Space")
        #expect(
            status {
                $0.unsafeShortcuts = some
                $0.stripHasRoom = false
            }?.level == .attention)
        #expect(
            title(
                status {
                    $0.unsafeShortcuts = some
                    $0.stripHasRoom = false
                }) != "The menu bar has no room for the strip")
        // Without Accessibility the shell's own banner speaks.
        #expect(
            status {
                $0.unsafeShortcuts = some
                $0.trusted = false
            } == nil)
    }

    @Test func theTextNamesOneKeyAFewKeysOrCountsTheRest() {
        #expect(String(localized: ShortcutWarning.detail([keys[0]])) == "⌥K types a character on this keyboard layout.")
        #expect(
            String(localized: ShortcutWarning.detail(Array(keys[0..<2])))
                == "⌥K, ⌥1 type characters on this keyboard layout.")
        #expect(
            String(localized: ShortcutWarning.detail(keys))
                == "⌥K, ⌥L, ⌥⇧H and 2 more type characters on this keyboard layout.")
        #expect(ShortcutWarning.name(of: KeyShortcut(key: "1", modifiers: [.option, .shift])) == "⌥⇧1")
        #expect(ShortcutWarning.name(of: KeyShortcut(key: "l", modifiers: [.control, .option])) == "⌃⌥L")
    }

    // MARK: The model feeds the banner and the fix changes only the flagged commands

    private func setup() throws -> (WindowsPlugin, WindowsHarness, ShortcutLog, WindowsSettingsModel) {
        let harness = try WindowsHarness()
        let log = ShortcutLog()
        let client = FakeWindowClient(windows: [makeWindow(1)])
        var context = harness.context(windows: client, permissions: ScriptedPermissions(granted: true))
        context = PluginContext(
            storageDirectory: harness.directory, settings: harness.pluginSettings, usage: NoUsage(),
            logger: context.logger, keychain: NoKeychain(), pasteboard: log, events: NoEvents(),
            workspace: NoWorkspace(), permissions: ScriptedPermissions(granted: true), clock: ContinuousClock(),
            windows: client,
            setCommandShortcut: { id, shortcut in log.set(id, shortcut) },
            commandShortcut: { id in log.get(id) })
        let plugin = WindowsPlugin(context: context, hud: RecordingHUD(), activationCenter: NotificationCenter())
        for command in plugin.commands {
            if let shortcut = command.defaultShortcut { log.set(command.id, shortcut) }
        }
        let model = WindowsSettingsModel(
            context: plugin.context, settings: plugin.settings, registry: .standard, runtime: { nil },
            translate: { Self.polish($0, $1) })
        return (plugin, harness, log, model)
    }

    @Test func theBannerFollowsTheRegisteredShortcutsAndTheFixClearsIt() async throws {
        let (plugin, harness, log, model) = try setup()
        defer { harness.tearDown() }
        model.refreshSafety()
        #expect(model.needsShortcutWarning)
        #expect(model.status.unsafeShortcuts == model.unsafeShortcuts)
        let before = Dictionary(
            uniqueKeysWithValues: plugin.commands.compactMap { command in log.get(command.id).map { (command.id, $0) } }
        )
        let banner = try #require(WindowsBanner.derive(model.status) { id in await model.perform(id) })
        #expect(banner.level == .attention)
        // Press the action the banner offers.
        guard case .plugin(_, let perform) = try #require(banner.fix.first).destination else {
            Issue.record("the action is not the plugin's own")
            return
        }
        await perform()
        #expect(!model.needsShortcutWarning)
        #expect(model.status.unsafeShortcuts.isEmpty)
        // Only the flagged commands changed; every other command kept its shortcut.
        let flagged = Set(
            before.filter { Self.polish(ShortcutSafety.keyCodes[$0.value.key] ?? 0, $0.value.modifiers) != nil }.keys)
        #expect(!flagged.isEmpty)
        for (id, shortcut) in before {
            let now = try #require(log.get(id))
            if flagged.contains(id) {
                #expect(now.modifiers.contains(.control) && now.modifiers.contains(.option))
                #expect(now.key == shortcut.key)
            } else {
                #expect(now == shortcut)
            }
        }
        // The family row of a partly changed family says Mixed, not the first binding's value.
        #expect(model.mixedFamilies.contains(.focus))
        #expect(model.choices[.focus] == nil)
        // Resetting the family from its modifier row undoes it.
        model.setModifiers(.option, for: .focus)
        #expect(log.get("windows.focus.right")?.modifiers == [.option])
        #expect(!model.mixedFamilies.contains(.focus))
    }

    @Test func aKeyboardLayoutThatTypesNothingShowsNoWarning() throws {
        let (plugin, harness, _, _) = try setup()
        defer { harness.tearDown() }
        let model = WindowsSettingsModel(
            context: plugin.context, settings: plugin.settings, registry: .standard, runtime: { nil },
            translate: { _, _ in nil })
        model.refreshSafety()
        #expect(!model.needsShortcutWarning)
        #expect(model.status.unsafeShortcuts.isEmpty)
    }

    // MARK: Letters before digits in the text (QA: "⌥1, ⌥4, ⌥5 and 14 more" hid ⌥L)

    @Test func theKeysThatEatALetterAreNamedBeforeTheDigits() {
        let digits = (1...9).map { KeyShortcut(key: String($0), modifiers: [.option]) }
        let letters = ["h", "k", "l"].map { KeyShortcut(key: $0, modifiers: [.option]) }
        let ordered = ShortcutWarning.ordered(digits + letters)
        #expect(Array(ordered.prefix(3)) == letters)
        // The order inside each group is the command order.
        #expect(Array(ordered.dropFirst(3)) == digits)
        #expect(ShortcutWarning.names(digits + letters) == "⌥H, ⌥K, ⌥L")
    }

    @Test func theModelListsFlaggedLettersFirst() throws {
        let (_, harness, _, model) = try setup()
        defer { harness.tearDown() }
        model.refreshSafety()
        let firstKeys = model.unsafeShortcuts.prefix(3).map(\.key)
        #expect(firstKeys.allSatisfy { $0.first?.isLetter == true }, "\(firstKeys)")
        let banner = WindowsBanner.derive(model.status) { _ in }
        #expect(String(localized: try #require(banner?.detail)).contains("⌥H"))
    }
}
