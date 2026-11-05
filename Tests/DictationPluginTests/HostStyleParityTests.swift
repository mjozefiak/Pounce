import AppKit
import Foundation
import LintelKit
import LintelUI
import SwiftUI
import Testing

@testable import DictationPlugin
@testable import LintelSpeech

/// Spec `2026-11-04-lintel-main-window`, step 3.3: the old Settings window (`.legacyWindow`, what release users
/// see) still draws the speech model card and the microphone rows; the main window draws the one-line summary
/// with its link to Models instead.
@MainActor
@Suite struct DictationHostStyleParityTests {
    /// The pane as the old window builds it: `settingsHostStyle` keeps its default (`.legacyWindow`) outside a
    /// host, which is what `SettingsWindowController` leaves it at.
    private func legacyPane(_ rig: DictationSettingsModelTests.Rig) -> DictationSettingsPane {
        let settings = DictationSettings(rig.harness.context.settings)
        return DictationSettingsPane(
            model: rig.model(),
            formatting: FormattingSettingsModel(
                settings: settings, transport: ScriptedTransport(.failure(.cannotConnectToHost))),
            history: HistorySettingsModel(
                settings: settings, history: DictationPlugin(context: rig.harness.context).history),
            recorder: AnyView(EmptyView()), isActive: false)
    }

    @Test func theOldWindowKeepsTheModelCardAndTheMicrophoneRows() throws {
        let rig = try DictationSettingsModelTests.Rig()
        defer { rig.harness.tearDown() }
        let types = ViewTree.typeNames(in: legacyPane(rig).body)
        #expect(types.contains("SpeechModelCard"))
        #expect(types.contains("MicrophoneRows"))
        #expect(types.contains("InputDevicePicker"))
        #expect(!types.contains("ModelChoiceRow"))
    }

    @Test func theOldWindowKeepsTheBuiltInModelRows() throws {
        let rig = try DictationSettingsModelTests.Rig()
        defer { rig.harness.tearDown() }
        let settings = DictationSettings(rig.harness.context.settings)
        settings.setMode(.cleanup)
        settings.setLLMSource(.builtIn)
        let directory = try TemporaryDirectory()
        let formatting = FormattingSettingsModel(
            settings: settings, transport: ScriptedTransport(.failure(.cannotConnectToHost)),
            llmModels: ModelManager(directory: directory.url, availableSpace: { _ in Int.max }),
            physicalMemory: UInt64(16) << 30)
        let types = ViewTree.typeNames(in: FormattingSection(model: formatting).body)
        #expect(types.contains("BuiltInModelRows"))
        #expect(!types.contains("ModelChoiceRow"))
    }

    @Test func bothHostsRender() throws {
        let rig = try DictationSettingsModelTests.Rig()
        defer { rig.harness.tearDown() }
        for style in [SettingsHostStyle.legacyWindow, .mainWindow] {
            let renderer = ImageRenderer(
                content: legacyPane(rig).environment(\.settingsHostStyle, style).frame(width: 600, height: 900))
            #expect(renderer.nsImage != nil)
        }
    }

    @Test func theSummaryNamesTheModelAndItsState() {
        #expect(
            ModelChoiceRow.summary(title: "Parakeet Ultra", state: .notInstalled) == "Parakeet Ultra · not installed")
        #expect(ModelChoiceRow.actionTitle(for: .notInstalled) == "Get it in Models")
        #expect(ModelChoiceRow.actionTitle(for: .installed) == "Manage in Models")
    }
}

/// The view types a `body` value holds, found by reflection: the branch an `if` took is stored as a value, the
/// other one is not, so this lists what the pane draws for the environment it was built in.
enum ViewTree {
    static func typeNames(in value: Any) -> Set<String> {
        var names: Set<String> = []
        collect(value, into: &names, depth: 0)
        return names
    }

    private static func collect(_ value: Any, into names: inout Set<String>, depth: Int) {
        guard depth < 60 else { return }
        let type = String(describing: Swift.type(of: value))
        names.insert(type.components(separatedBy: "<").first ?? type)
        for child in Mirror(reflecting: value).children {
            collect(child.value, into: &names, depth: depth + 1)
        }
    }
}
