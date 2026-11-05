import Foundation
import LintelKit
import Testing

@testable import LintelApp

private let sourcesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Sources/LintelApp/Settings")

/// The main window's Permissions rows (step 6.5c): order, state text and help.
@Suite struct PermissionRowFidelityTests {
    private func row(_ permission: Permission, _ status: PermissionStatus, needed: Bool = true) -> PermissionRowState {
        PermissionRowState(permission: permission, status: status, pluginNames: needed ? ["Dictation"] : [])
    }

    @Test func problemsComeFirstThenAllowedThenUnused() {
        let rows = [
            row(.accessibility, .granted),
            row(.fullDiskAccess, .denied, needed: false),
            row(.microphone, .notDetermined),
            row(.systemAudioRecording, .notDetermined),
            row(.pasteboard, .denied),
        ]
        #expect(
            PermissionRowState.problemsFirst(rows).map(\.permission)
                == [.microphone, .systemAudioRecording, .pasteboard, .accessibility, .fullDiskAccess])
    }

    @Test func mainStateTextPerStatus() {
        #expect(row(.microphone, .granted).mainStateText == "Allowed")
        #expect(row(.microphone, .denied).mainStateText == "Not allowed")
        #expect(row(.microphone, .notDetermined).mainStateText == "Not asked yet")
        #expect(row(.accessibility, .notDetermined).mainStateText == "Not asked yet")
        #expect(row(.systemAudioRecording, .notDetermined).mainStateText == "Can't be checked")
        #expect(row(.pasteboard, .notDetermined).mainStateText == "Asks or follows the system default")
        #expect(row(.pasteboard, .granted).mainStateText == "Always allowed")
    }

    @Test func theStateTextSaysUnknownBeforeMacOSAsked() {
        #expect(row(.microphone, .notDetermined).stateText == "Unknown")
    }

    @Test func allowMicrophoneOnlyBeforeMacOSAsked() {
        #expect(row(.microphone, .notDetermined).allowTitle == "Allow Microphone")
        #expect(row(.microphone, .denied).allowTitle == nil)
        #expect(row(.accessibility, .notDetermined).allowTitle == nil)
    }

    @Test func theRowKeepsItsExplanationInHelp() throws {
        let source = try String(contentsOf: sourcesRoot.appending(path: "PermissionRow.swift"), encoding: .utf8)
        #expect(source.contains(".help(permission.explanation)"))
        // The main window row has no leading icon and shows the state on the right ("✓ Allowed").
        let main = try #require(
            source.components(separatedBy: "var body: some View").last?
                .components(separatedBy: "@ViewBuilder private var openButton").first)
        #expect(!main.contains("symbolName"))
        #expect(main.contains("stateLabel"))
        #expect(main.contains("\"checkmark\""))
        #expect(main.contains("Text(neededText)"))
        let pane = try String(contentsOf: sourcesRoot.appending(path: "PermissionsPane.swift"), encoding: .utf8)
        #expect(pane.contains("problemsFirst(model.rows)"))
    }

    @Test func theBannerNamesTheFeaturesAndThePermissions() {
        let one = ShellPaneBanners.permissions(
            requirements: [PermissionRequirement(permission: .microphone, pluginNames: ["Dictation", "Meetings"])],
            status: { _ in .notDetermined })
        #expect(
            one.detail == "Dictation and Meetings can't start until \(Permission.microphone.title) is allowed.")
        let two = ShellPaneBanners.permissions(
            requirements: [
                PermissionRequirement(permission: .microphone, pluginNames: ["Dictation"]),
                PermissionRequirement(permission: .accessibility, pluginNames: ["Dictation"]),
            ], status: { _ in .denied })
        #expect(two.detail?.contains("Dictation can't start until") == true)
        #expect(two.detail?.hasSuffix("are allowed.") == true)
    }
}
