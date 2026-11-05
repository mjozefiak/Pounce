import AVFoundation
import AppKit
import Foundation
import KeyboardShortcuts
import LintelKit
import SwiftUI
import Testing

@testable import LintelApp

@MainActor
final class NoLaunchAtLogin: LaunchAtLoginClient {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

@MainActor final class Counter { var count = 0 }

@MainActor final class Flags { var values: [Bool] = [] }

@MainActor
final class PhaseLog {
    var phases: [KeyPhase] = []
    var ran = 0
}

@MainActor
@Suite struct KeyEventDeliveryTests {
    private func command(_ id: String, log: PhaseLog, withKeyEvents: Bool) -> PluginCommand {
        if withKeyEvents {
            return PluginCommand(id: id, title: "Command", run: { log.ran += 1 }, onKeyEvent: { log.phases.append($0) })
        }
        return PluginCommand(id: id, title: "Command", run: { log.ran += 1 })
    }

    @Test func phasesArriveSynchronouslyAndInOrder() {
        let registrar = InMemoryHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar, settings: InMemorySettingsStore(), readOccupied: { [] })
        let log = PhaseLog()
        let keyed = command("dictation.record", log: log, withKeyEvents: true)
        service.syncCommands(
            [keyed], perform: { _ in log.ran += 1 },
            deliver: { command, phase in command.onKeyEvent?(phase) })
        let name = HotkeyName.command("dictation.record")
        #expect(registrar.handlers[name] == nil)
        // A fast tap: down and up in the same turn of the event loop, no `await` in between.
        registrar.keyEventHandlers[name]?(.down)
        registrar.keyEventHandlers[name]?(.up)
        #expect(log.phases == [.down, .up])
        #expect(log.ran == 0)
    }

    @Test func aCommandWithoutKeyEventsStillRunsOnKeyDown() {
        let registrar = InMemoryHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar, settings: InMemorySettingsStore(), readOccupied: { [] })
        let log = PhaseLog()
        service.syncCommands([command("plain", log: log, withKeyEvents: false)], perform: { _ in log.ran += 1 })
        let name = HotkeyName.command("plain")
        #expect(registrar.keyEventHandlers[name] == nil)
        registrar.handlers[name]?()
        #expect(log.ran == 1)
        #expect(log.phases.isEmpty)
    }

    @Test func aRemovedCommandLosesItsKeyEventHandler() {
        let registrar = InMemoryHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar, settings: InMemorySettingsStore(), readOccupied: { [] })
        let log = PhaseLog()
        service.syncCommands([command("dictation.record", log: log, withKeyEvents: true)], perform: { _ in })
        service.syncCommands([], perform: { _ in })
        #expect(registrar.keyEventHandlers[.command("dictation.record")] == nil)
    }

    @Test func oneStreamKeepsDownBeforeUpAndStopsAfterCancel() async {
        let log = PhaseLog()
        let (events, continuation) = AsyncStream<KeyboardShortcuts.EventType>.makeStream()
        let task = KeyboardShortcutsRegistrar.forward(events) { log.phases.append($0) }
        continuation.yield(.keyDown)
        continuation.yield(.keyUp)
        continuation.yield(.keyDown)
        continuation.yield(.keyUp)
        continuation.finish()
        await task.value
        #expect(log.phases == [.down, .up, .down, .up])

        let (more, moreContinuation) = AsyncStream<KeyboardShortcuts.EventType>.makeStream()
        let cancelled = KeyboardShortcutsRegistrar.forward(more) { log.phases.append($0) }
        cancelled.cancel()
        await cancelled.value
        moreContinuation.yield(.keyDown)
        await Task.yield()
        #expect(log.phases.count == 4)
    }
}

@MainActor
@Suite struct EscapeClaimTests {
    private func service(_ registrar: InMemoryHotkeyRegistrar) -> HotkeyService {
        HotkeyService(registrar: registrar, settings: InMemorySettingsStore(), readOccupied: { [] })
    }

    @Test func aSecondClaimIsInactiveAndReleaseFreesTheKey() {
        let registrar = InMemoryHotkeyRegistrar()
        let service = service(registrar)
        let first = service.claimEscape {}
        #expect(first.isActive)
        #expect(registrar.escapeAction != nil)

        let second = service.claimEscape {}
        #expect(!second.isActive)
        second.release()
        #expect(registrar.escapeAction != nil)

        first.release()
        first.release()
        #expect(registrar.escapeAction == nil)
        #expect(registrar.escapeReleases == 1)
        #expect(service.claimEscape {}.isActive)
    }

    @Test func aStaleHandleReleasedAgainDoesNotFreeTheNewClaim() {
        let registrar = InMemoryHotkeyRegistrar()
        let service = service(registrar)
        let first = service.claimEscape {}
        first.release()
        let second = service.claimEscape {}
        first.release()
        #expect(second.isActive)
        #expect(!service.claimEscape {}.isActive)
        second.release()
    }

    @Test func aBlockedRegistrationGivesAnInactiveClaim() {
        let registrar = InMemoryHotkeyRegistrar()
        registrar.escapeAvailable = false
        let service = service(registrar)
        #expect(!service.claimEscape {}.isActive)
        registrar.escapeAvailable = true
        #expect(service.claimEscape {}.isActive)
    }

    @Test func escapeCallsTheHandler() {
        let registrar = InMemoryHotkeyRegistrar()
        let pressed = Counter()
        let claim = service(registrar).claimEscape { pressed.count += 1 }
        registrar.escapeAction?()
        #expect(pressed.count == 1)
        claim.release()
    }

    @Test func contextsReachTheShellClaim() throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let claimed = Counter()
        let context = test.environment.makeContext(
            for: PluginManifest(id: "dictation", displayName: "Dictation", symbolName: "mic", order: 40),
            claimEscapeKey: { _ in
                claimed.count += 1
                return EscapeKeyClaim(isActive: true)
            })
        #expect(context.claimEscapeKey({}).isActive)
        #expect(claimed.count == 1)
        let defaulted = test.environment.makeContext(
            for: PluginManifest(id: "other", displayName: "Other", symbolName: "mic", order: 41))
        #expect(!defaulted.claimEscapeKey({}).isActive)
    }
}

@MainActor
@Suite struct CoordinatorContractTests {
    private func coordinator(_ test: TestEnvironment, types: [any LintelPlugin.Type] = []) -> AppCoordinator {
        AppCoordinator(
            environment: test.environment, pluginTypes: types, registrar: InMemoryHotkeyRegistrar(),
            occupiedShortcuts: { [] }, launchAtLogin: NoLaunchAtLogin())
    }

    @Test func aVisiblePanelIsHiddenBeforeKeyDownReachesThePlugin() throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let coordinator = coordinator(test)
        let log = PhaseLog()
        let panelWasVisible = Flags()
        let command = PluginCommand(
            id: "dictation.record", title: "Dictate",
            onKeyEvent: { phase in
                panelWasVisible.values.append(coordinator.panelModel.isVisible)
                log.phases.append(phase)
            })
        coordinator.panelModel.show()
        #expect(coordinator.panelModel.isVisible)
        coordinator.deliver(command, phase: .down)
        coordinator.deliver(command, phase: .up)
        #expect(log.phases == [.down, .up])
        #expect(panelWasVisible.values == [false, false])
    }

    @Test func enablingAPluginShowsItsPendingOnboardingSteps() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let coordinator = coordinator(test, types: [StepPlugin.self])
        let shown = Counter()
        coordinator.presentPendingOnboarding = { shown.count += 1 }
        await coordinator.host.setEnabled(true, for: "step")
        coordinator.pluginsChanged()
        #expect(shown.count == 1)
    }
}

@MainActor final class StepPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "step", displayName: "Step", symbolName: "star", order: 90, defaultEnabled: false)
    init(context: PluginContext) {}
    var onboardingSteps: [OnboardingStep] {
        [OnboardingStep(id: "step.intro", title: "Intro", symbolName: "star") { AnyView(EmptyView()) }]
    }
}

@MainActor
@Suite struct MicrophonePermissionTests {
    @Test func authorizationMapsToStatus() {
        #expect(SystemPermissionsReader.status(for: .authorized) == .granted)
        #expect(SystemPermissionsReader.status(for: .denied) == .denied)
        #expect(SystemPermissionsReader.status(for: .restricted) == .denied)
        #expect(SystemPermissionsReader.status(for: .notDetermined) == .notDetermined)
    }

    @Test func theOverrideDecidesTheMicrophoneRow() {
        let reader = SystemPermissionsReader(microphoneOverride: .denied)
        #expect(reader.status(of: .microphone) == .denied)
    }

    @Test func settingsLinkToThePrivacyPane() {
        #expect(
            Permission.microphone.settingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }
}
