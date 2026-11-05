import Foundation
import LintelKit
import Testing

@testable import LintelApp

@MainActor
final class FakePermissionRequester: PermissionRequester {
    private(set) var requested: [Permission] = []
    /// What the reader answers once the user has clicked.
    var onRequest: () -> Void = {}

    func request(_ permission: Permission) async {
        requested.append(permission)
        onRequest()
    }
}

/// Spec `2026-11-04-lintel-main-window` step 3.1: the one `PermissionRow` and the pane's rows.
@MainActor
@Suite struct PermissionRowTests {
    private func makeModel(
        _ test: TestEnvironment, plugins: [any LintelPlugin.Type], reader: FakePermissionsReader,
        requester: FakePermissionRequester = FakePermissionRequester()
    ) async -> PermissionsModel {
        let host = test.makeHost(plugins)
        await host.start()
        return PermissionsModel(host: host, reader: reader, requester: requester) { _ in }
    }

    @Test func theMainWindowHasOneRowPerPermissionAndDimsTheUnused() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let model = await makeModel(test, plugins: [PastingPlugin.self], reader: FakePermissionsReader())
        model.includesUnused = true
        model.refresh()

        #expect(model.rows.map(\.permission) == Permission.allCases)
        let dimmed = Set(model.rows.filter(\.isDimmed).map(\.permission))
        #expect(dimmed == Set(Permission.allCases).subtracting([.accessibility, .pasteboard]))
        #expect(model.rows.first { $0.permission == .accessibility }?.pluginNames == ["Pasting"])

        // The old window keeps listing only what the enabled features need.
        model.includesUnused = false
        #expect(model.rows.map(\.permission) == [.accessibility, .pasteboard])
        #expect(model.rows.allSatisfy { !$0.isDimmed })
    }

    @Test func stateTextFollowsThePermissionStatus() {
        let denied = PermissionRowState(permission: .microphone, status: .denied, pluginNames: ["A"])
        #expect(denied.stateText == "Not allowed")
        #expect(denied.tone == .problem)
        let granted = PermissionRowState(permission: .accessibility, status: .granted, pluginNames: ["A"])
        #expect(granted.stateText == "Allowed")
        #expect(granted.tone == .ok)
        let unknown = PermissionRowState(permission: .accessibility, status: .notDetermined, pluginNames: ["A"])
        #expect(unknown.stateText == "Unknown")
        #expect(unknown.tone == .neutral)
        for status: PermissionStatus in [.granted, .denied, .notDetermined] {
            #expect(!PermissionRowState(permission: .pasteboard, status: status, pluginNames: []).stateText.isEmpty)
        }
    }

    @Test func anUnreadablePermissionIsNeutralWhateverItsStatus() {
        #expect(!Permission.systemAudioRecording.isReadable)
        for status: PermissionStatus in [.granted, .denied, .notDetermined] {
            let row = PermissionRowState(permission: .systemAudioRecording, status: status, pluginNames: ["R"])
            #expect(row.tone == .neutral)
            #expect(row.allowTitle == nil)
        }
        let row = PermissionRowState(permission: .systemAudioRecording, status: .notDetermined, pluginNames: ["R"])
        #expect(row.stateText == "Can't be checked")
    }

    @Test func allowMicrophoneShowsOnlyForANotDeterminedMicrophone() {
        let notDetermined = PermissionRowState(permission: .microphone, status: .notDetermined, pluginNames: ["R"])
        #expect(notDetermined.allowTitle == "Allow Microphone")
        for status: PermissionStatus in [.granted, .denied] {
            #expect(PermissionRowState(permission: .microphone, status: status, pluginNames: []).allowTitle == nil)
        }
        for permission in Permission.allCases where permission != .microphone {
            #expect(
                PermissionRowState(permission: permission, status: .notDetermined, pluginNames: []).allowTitle == nil)
        }
    }

    @Test func allowMicrophoneCallsTheRequesterAndReadsAgain() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let reader = FakePermissionsReader()
        let requester = FakePermissionRequester()
        requester.onRequest = { reader.answers[.microphone] = .granted }
        let model = await makeModel(test, plugins: [RecordingPlugin.self], reader: reader, requester: requester)
        await model.host.setEnabled(true, for: "recording")
        model.refresh()
        #expect(model.rows.first { $0.permission == .microphone }?.allowTitle == "Allow Microphone")
        #expect(requester.requested.isEmpty, "nothing is requested before a click")

        let readsBefore = reader.reads.count
        await model.allow(.microphone)
        #expect(requester.requested == [.microphone])
        #expect(reader.reads.count > readsBefore)
        #expect(model.status(of: .microphone) == .granted)
        #expect(model.rows.first { $0.permission == .microphone }?.allowTitle == nil)
    }
}
