import LintelKit
import Testing

@testable import LintelApp
@testable import WindowsPlugin

/// Phase 0, step 0.6 of window management v2: the shortcut layer (Carbon, key translation) is not part of a `--qa`
/// run, so it is tested here with the in-memory registrar and a table of what the Polish Pro layout types.
/// Every default shortcut that is registered and types a character must be named by the banner at the top of the
/// pane; registration itself does not change (Q3: register everything, only warn).
@MainActor
@Suite struct WindowsShortcutWarningTests {
    /// Polish Pro, as measured in QA (spec, Problem Statement): with ⌥ held the keys 1, 4, 5, 9, H, K and L type a
    /// character; with ⌥⇧ held 1, 2, 5, 6, 7, 9, H, J, K and L do. Everything else types nothing.
    static let polishPro: ShortcutSafety.KeyTranslation = { code, modifiers in
        guard !modifiers.contains(.control), !modifiers.contains(.command), modifiers.contains(.option) else {
            return nil
        }
        let option: Set<String> = ["1", "4", "5", "9", "h", "k", "l"]
        let optionShift: Set<String> = ["1", "2", "5", "6", "7", "9", "h", "j", "k", "l"]
        let keys = modifiers.contains(.shift) ? optionShift : option
        guard let key = ShortcutSafety.keyCodes.first(where: { $0.value == code })?.key, keys.contains(key) else {
            return nil
        }
        return "ł"
    }

    private struct Rig {
        let environment: TestEnvironment
        let registrar: InMemoryHotkeyRegistrar
        let service: HotkeyService
        let plugin: WindowsPlugin
    }

    private func rig() throws -> Rig {
        let environment = try TestEnvironment()
        let registrar = InMemoryHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar, settings: environment.settings, readOccupied: { [] })
        let context = environment.environment.makeContext(
            for: WindowsPlugin.manifest,
            setCommandShortcut: { service.setCommandShortcut($0, $1) },
            commandShortcut: { service.commandShortcut($0)?.portable })
        let plugin = WindowsPlugin(context: context)
        service.syncCommands(plugin.commands, perform: { _ in })
        return Rig(environment: environment, registrar: registrar, service: service, plugin: plugin)
    }

    private func registered(_ rig: Rig) -> [(id: String, shortcut: KeyShortcut)] {
        rig.plugin.commands.compactMap { command in
            rig.registrar.shortcut(for: .command(command.id))?.portable.map { (command.id, $0) }
        }
    }

    @Test func everyRegisteredDefaultThatTypesACharacterIsNamedInTheBanner() throws {
        let rig = try rig()
        defer { rig.environment.tearDown() }
        let bound = registered(rig)
        // Registration is unchanged: every command with a default shortcut got it (Q3).
        #expect(bound.count == rig.plugin.commands.compactMap(\.defaultShortcut).count)
        let expected = bound.filter { item in
            ShortcutSafety.keyCodes[item.shortcut.key].flatMap { Self.polishPro($0, item.shortcut.modifiers) } != nil
        }
        #expect(!expected.isEmpty)

        let model = WindowsSettingsModel(
            context: rig.plugin.context, settings: rig.plugin.settings, registry: .standard, runtime: { nil },
            translate: Self.polishPro)
        model.refreshSafety()
        // The banner covers exactly the registered shortcuts that type, none missed and none invented.
        #expect(Set(model.flagged.map(\.id)) == Set(expected.map(\.id)), "flagged: \(model.flagged.map(\.id))")
        let banner = try #require(WindowsBanner.derive(model.status) { _ in })
        #expect(banner.level == .attention)
        #expect(String(localized: banner.title).contains("\(expected.count)"))
        // The detail names the first of them (in command order) and counts the rest.
        let detail = String(localized: try #require(banner.detail))
        let named = ShortcutWarning.ordered(expected.map(\.shortcut)).prefix(ShortcutWarning.namedKeys)
        for shortcut in named {
            #expect(detail.contains(ShortcutWarning.name(of: shortcut)), "\(shortcut) is not in: \(detail)")
        }
        if expected.count > ShortcutWarning.namedKeys {
            #expect(detail.contains("\(expected.count - ShortcutWarning.namedKeys) more"))
        }
    }

    @Test func theFixChangesOnlyTheFlaggedCommandsAndTheRegistrationFollows() throws {
        let rig = try rig()
        defer { rig.environment.tearDown() }
        let before = Dictionary(uniqueKeysWithValues: registered(rig).map { ($0.id, $0.shortcut) })
        let model = WindowsSettingsModel(
            context: rig.plugin.context, settings: rig.plugin.settings, registry: .standard, runtime: { nil },
            translate: Self.polishPro)
        model.refreshSafety()
        let flagged = Set(model.flagged.map(\.id))
        model.useControlOption()
        #expect(!model.needsShortcutWarning)
        for (id, shortcut) in before {
            let now = rig.registrar.shortcut(for: .command(id))?.portable
            if flagged.contains(id) {
                #expect(now == ShortcutSafety.controlOption(for: [shortcut]).first, "\(id)")
            } else {
                #expect(now == shortcut, "\(id) must not change")
            }
        }
    }

    @Test func aLayoutThatTypesNothingShowsNoWarning() throws {
        let rig = try rig()
        defer { rig.environment.tearDown() }
        let model = WindowsSettingsModel(
            context: rig.plugin.context, settings: rig.plugin.settings, registry: .standard, runtime: { nil },
            translate: { _, _ in nil })
        model.refreshSafety()
        #expect(WindowsBanner.derive(model.status) { _ in }?.level == .ok)
    }
}
