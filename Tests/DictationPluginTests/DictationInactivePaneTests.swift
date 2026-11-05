import AppKit
import Foundation
import LintelKit
import SwiftUI
import Testing

@testable import DictationPlugin
@testable import LintelSpeech

/// `settingsPane()` may be drawn while the plugin is off (the main window shows it dimmed); its `.task` then
/// probes no server and reads no model folder.
@MainActor
@Suite struct DictationInactivePaneTests {
    private func render(isActive: Bool) async throws -> (ScriptedTransport, DictationSettingsModel) {
        let rig = try DictationSettingsModelTests.Rig()
        defer { rig.harness.tearDown() }
        let settings = DictationSettings(rig.harness.context.settings)
        // Formatting was switched on earlier, so an appearing pane would probe the local servers.
        settings.setMode(.cleanup)
        let transport = ScriptedTransport(.failure(.cannotConnectToHost))
        let formatting = FormattingSettingsModel(settings: settings, transport: transport)
        let model = rig.model()
        let pane = DictationSettingsPane(
            model: model, formatting: formatting,
            history: HistorySettingsModel(
                settings: settings, history: DictationPlugin(context: rig.harness.context).history),
            recorder: AnyView(EmptyView()), isActive: isActive)
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 800), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: pane)
        window.orderFrontRegardless()
        defer { window.close() }
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(10))
            if isActive, !transport.requests.isEmpty { break }
        }
        return (transport, model)
    }

    @Test func anInactivePaneProbesNoServerAndReadsNothing() async throws {
        let (transport, model) = try await render(isActive: false)
        #expect(transport.requests.isEmpty)
        #expect(model.devices.isEmpty)
    }

    @Test func anActivePaneRefreshesAsBefore() async throws {
        let (transport, model) = try await render(isActive: true)
        #expect(!transport.requests.isEmpty)
        #expect(!model.devices.isEmpty)
    }
}
