import AppKit
import Foundation
import LintelKit
import SwiftUI
import Testing

@testable import MeetingsPlugin

/// `settingsPane()` may be drawn while the plugin is off (the main window shows it dimmed); its `.task` then
/// reads no model folder and no device list.
@MainActor
@Suite struct MeetingsInactivePaneTests {
    private func render(isActive: Bool) async throws -> SettingsRig {
        let rig = try SettingsRig()
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 800), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: MeetingsSettingsPane(model: rig.model, recorder: nil, isActive: isActive))
        window.orderFrontRegardless()
        defer { window.close() }
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(10))
            if isActive, !rig.model.devices.isEmpty { break }
        }
        return rig
    }

    @Test func anInactivePaneReadsNothing() async throws {
        let rig = try await render(isActive: false)
        #expect(rig.model.devices.isEmpty)
    }

    @Test func anActivePaneRefreshesAsBefore() async throws {
        let rig = try await render(isActive: true)
        #expect(rig.model.devices.map(\.name) == ["USB mic"])
    }
}
