import Foundation
import PounceKit
import SwiftUI
import Testing

@testable import PounceApp

/// Offers a control under the System Audio Recording row, like the meetings plugin's "Test" button.
final class TestableRecordingPlugin: PouncePlugin {
    static let manifest = PluginManifest(
        id: "testable", displayName: "Testable", symbolName: "waveform", order: 4, defaultEnabled: false)

    init(context: PluginContext) {}

    var requiredPermissions: Set<Permission> { [.microphone, .systemAudioRecording] }

    func permissionAccessory(for permission: Permission) -> AnyView? {
        permission == .systemAudioRecording ? AnyView(Text("Test")) : nil
    }
}

@MainActor
@Suite struct PermissionAccessoryTests {
    @Test func aRowShowsTheAccessoriesOfTheEnabledPluginsThatNeedIt() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([PastingPlugin.self, TestableRecordingPlugin.self])
        await host.start()
        let model = PermissionsModel(host: host, reader: FakePermissionsReader()) { _ in }
        #expect(model.accessories(for: .systemAudioRecording).isEmpty)

        await host.setEnabled(true, for: "testable")
        #expect(model.accessories(for: .systemAudioRecording).count == 1)
        // Only the permission it asked for.
        #expect(model.accessories(for: .microphone).isEmpty)
        #expect(model.accessories(for: .accessibility).isEmpty)

        await host.setEnabled(false, for: "testable")
        #expect(model.accessories(for: .systemAudioRecording).isEmpty)
    }
}
