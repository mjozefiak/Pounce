import LintelKit
import Testing

@testable import LintelApp

/// Spec `2026-11-04-lintel-main-window`, step 2.1: the Settings sidebar groups and orders from manifests only.
@Suite struct SettingsSidebarModelTests {
    private typealias Plugin = SettingsSidebarModel.PluginItem

    private func plugin(
        _ id: String, group: SettingsGroup, order: Int, active: Bool = true, attention: Bool = false
    ) -> Plugin {
        Plugin(
            id: id, title: id.capitalized, symbolName: "app", group: group, order: order, isActive: active,
            needsAttention: attention)
    }

    private var sample: [Plugin] {
        [
            plugin("files", group: .search, order: 20),
            plugin("meetings", group: .voice, order: 50, active: false),
            plugin("apps", group: .search, order: 10),
            plugin("dictation", group: .voice, order: 40),
            plugin("clipboard", group: .search, order: 30),
        ]
    }

    @Test func fiveGroupsInTheSpecOrder() {
        let sections = SettingsSidebarModel.sections(plugins: sample)
        #expect(sections.map(\.id) == ["lintel", "search", "voice", "models", "advanced"])
    }

    @Test func pluginsAreGroupedAndOrderedByTheirManifest() {
        let sections = SettingsSidebarModel.sections(plugins: sample)
        #expect(sections[1].items.map(\.id) == ["apps", "files", "clipboard"])
        #expect(sections[2].items.map(\.id) == ["dictation", "meetings"])
    }

    @Test func theLintelGroupHoldsShellPanesAroundItsPluginPanes() {
        let extra = [plugin("zeta", group: .lintel, order: 2), plugin("alpha", group: .lintel, order: 1)]
        let sections = SettingsSidebarModel.sections(plugins: extra)
        #expect(sections[0].items.map(\.id) == ["general", "features", "alpha", "zeta", "permissions"])
    }

    @Test func aPluginMovesWithItsManifestGroupNotItsId() {
        let moved = [plugin("apps", group: .voice, order: 1), plugin("files", group: .voice, order: 0)]
        let sections = SettingsSidebarModel.sections(plugins: moved)
        #expect(sections.map(\.id) == ["lintel", "voice", "models", "advanced"])
        #expect(sections[1].items.map(\.id) == ["files", "apps"])
    }

    @Test func anUnknownGroupComesAfterVoiceAndAnEmptyGroupIsOmitted() {
        let sections = SettingsSidebarModel.sections(plugins: [
            plugin("x", group: SettingsGroup(rawValue: "extra"), order: 1)
        ])
        #expect(sections.map(\.id) == ["lintel", "extra", "models", "advanced"])
    }

    @Test func theFocusOrderIsEveryItemTopToBottom() {
        let order = SettingsSidebarModel.focusOrder(SettingsSidebarModel.sections(plugins: sample))
        #expect(
            order == [
                "general", "features", "permissions", "apps", "files", "clipboard", "dictation", "meetings", "models",
                "advanced",
            ])
        #expect(Set(order).count == order.count)
    }

    @Test func modelsIsInTheModelAndMatchesTheRouter() {
        #expect(SettingsSidebarModel.modelsID == MainWindowRouter.modelsPaneID)
        let order = SettingsSidebarModel.focusOrder(SettingsSidebarModel.sections(plugins: []))
        #expect(order == ["general", "features", "permissions", "models", "advanced"])
    }

    @Test func aDisabledPluginStaysInPlaceAndSaysOff() throws {
        let sections = SettingsSidebarModel.sections(plugins: sample)
        let off = try #require(sections[2].items.first { $0.id == "meetings" })
        #expect(!off.isActive)
        #expect(off.accessibilityLabel == "Meetings, \(String(localized: "Off", comment: "Feature state"))")
    }

    @Test func theAttentionDotIsSpokenAndNeverShownOnAnOffRow() throws {
        let sections = SettingsSidebarModel.sections(plugins: [
            plugin("apps", group: .search, order: 1, attention: true),
            plugin("files", group: .search, order: 2, active: false, attention: true),
        ])
        let apps = try #require(sections[1].items.first { $0.id == "apps" })
        let files = try #require(sections[1].items.first { $0.id == "files" })
        #expect(apps.needsAttention)
        #expect(apps.accessibilityLabel.contains(String(localized: "Needs attention")))
        #expect(!files.needsAttention)
    }
}
