import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// Step 1.8c: per-process ordering, the pure conversions, and the wiring of the window client into the plugin
/// context. The real Accessibility calls are a manual item (`docs/qa.md`).
@Suite struct AXWindowClientTests {
    @Test func workForOneProcessRunsInTheOrderOfSubmissionAndNeverOverlaps() async {
        let queues = PerProcessQueues()
        let log = Ordered()
        // The first piece holds the queue until every piece is queued: later ones must still wait for it.
        let gate = DispatchSemaphore(value: 0)
        for index in 0..<20 {
            queues.enqueue(pid: 1) {
                log.enter()
                if index == 0 { gate.wait() }
                log.append(index)
                log.leave()
            }
        }
        gate.signal()
        await queues.run(pid: 1) {}
        #expect(log.values == Array(0..<20))
        #expect(log.maxConcurrent == 1)
    }

    @Test func aResultComesBackToItsCaller() async {
        let queues = PerProcessQueues()
        async let one: Int = queues.run(pid: 2) { 1 }
        async let two: Int = queues.run(pid: 3) { 2 }
        #expect(await (one, two) == (1, 2))
    }

    @Test func differentProcessesRunInParallel() async {
        let queues = PerProcessQueues()
        let log = Ordered()
        // Each piece waits for the other to have started: that only happens when they run at the same time.
        let firstIn = DispatchSemaphore(value: 0)
        let secondIn = DispatchSemaphore(value: 0)
        async let first: Void = queues.run(pid: 10) {
            log.enter()
            firstIn.signal()
            _ = secondIn.wait(timeout: .now() + 5)
            log.leave()
        }
        async let second: Void = queues.run(pid: 11) {
            log.enter()
            secondIn.signal()
            _ = firstIn.wait(timeout: .now() + 5)
            log.leave()
        }
        _ = await (first, second)
        #expect(log.maxConcurrent == 2)
        #expect(queues.count == 2)
        queues.forget(pid: 10)
        #expect(queues.count == 1)
    }

    @Test func accessibilityErrorsMapToThePortsErrors() {
        #expect(WindowGeometry.clientError(for: .success) == nil)
        #expect(WindowGeometry.clientError(for: .invalidUIElement) == .windowGone)
        #expect(WindowGeometry.clientError(for: .cannotComplete) == .timedOut)
        #expect(WindowGeometry.clientError(for: .apiDisabled) == .notTrusted)
        #expect(WindowGeometry.clientError(for: .attributeUnsupported) == .refused)
        #expect(WindowGeometry.clientError(for: .illegalArgument) == .refused)
        #expect(WindowGeometry.clientError(for: .failure) == .refused)
    }

    @Test func appKitFramesBecomeTopLeftFrames() {
        // A secondary display above the primary one has a negative top in the Accessibility space.
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let above = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        #expect(
            WindowGeometry.accessibilityFrame(of: primary, primaryHeight: 1080)
                == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(
            WindowGeometry.accessibilityFrame(of: above, primaryHeight: 1080)
                == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        // The menu bar and the Dock shrink the visible frame from the top and the bottom.
        let visible = CGRect(x: 0, y: 70, width: 1920, height: 985)
        #expect(
            WindowGeometry.accessibilityFrame(of: visible, primaryHeight: 1080)
                == CGRect(x: 0, y: 25, width: 1920, height: 985))
    }

    @Test func aProcessStartIsReadForThisProcessAndNotForAMissingOne() throws {
        let start = try #require(ProcessStart.read(pid: ProcessInfo.processInfo.processIdentifier))
        let now = Date().timeIntervalSince1970
        #expect(start < now)
        #expect(start > now - 365 * 24 * 3600)
        #expect(ProcessStart.read(pid: 999_999) == nil)
        #expect(ProcessStart.read(pid: 0) == nil)
        #expect(ProcessStart.read(pid: -4) == nil)
    }

    @Test func aQuitAppIsForgottenByTheClient() async {
        let queues = PerProcessQueues()
        let client = AXWindowClient(lookup: WindowIDLookup(resolver: { nil }), queues: queues)
        await queues.run(pid: 4242) {}
        #expect(queues.count == 1)
        client.forget(pid: 4242)
        #expect(queues.count == 0)
        #expect(client.cachedProcessCount == 0)
    }

    @Test func withoutTheSymbolTheClientIsUnsupportedAndNeverObserves() {
        let client = AXWindowClient(lookup: WindowIDLookup(resolver: { nil }))
        #expect(client.availability == .unsupported(reason: WindowIDSelfCheck.missingReason))
    }

    // MARK: Wiring

    @MainActor
    @Test func theEnvironmentHandsItsWindowClientToEveryPluginContext() throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let marker = MarkerWindowClient()
        var environment = test.environment
        environment.windowClient = marker
        let context = environment.makeContext(
            for: PluginManifest(id: "other", displayName: "Other", symbolName: "mic", order: 1))
        #expect(context.windows is MarkerWindowClient)
        // The default is the client that reports nothing, never the real one.
        let defaulted = test.environment.makeContext(
            for: PluginManifest(id: "other", displayName: "Other", symbolName: "mic", order: 1))
        #expect(defaulted.windows is NoWindowClient)
        #expect(defaulted.windows.availability == .unsupported(reason: "No window client"))
    }
}

nonisolated private struct MarkerWindowClient: WindowClient {
    var availability: WindowClientAvailability { .available }
    func windows() async -> [WindowInfo] { [] }
    func focusedWindow() async -> WindowID? { nil }
    func setFrame(_ frame: CGRect, for id: WindowID) async throws(WindowClientError) -> CGRect { frame }
    func focus(_ id: WindowID) async throws(WindowClientError) {}
    func displays() async -> [DisplayInfo] { [] }
    func subscribe() async -> AsyncStream<WindowEvent> { AsyncStream { $0.finish() } }
}

nonisolated private final class Ordered: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxConcurrent = 0
    private var _values: [Int] = []

    var values: [Int] { lock.withLock { _values } }
    func append(_ value: Int) { lock.withLock { _values.append(value) } }

    func enter() {
        lock.withLock {
            inFlight += 1
            maxConcurrent = max(maxConcurrent, inFlight)
        }
    }

    func leave() { lock.withLock { inFlight -= 1 } }
}

/// Step 1.9: the programmatic shortcut setter and the portable form of a registered shortcut.
@MainActor
@Suite struct CommandShortcutSetterTests {
    private func service() throws -> (HotkeyService, InMemoryHotkeyRegistrar, InMemorySettingsStore) {
        let registrar = InMemoryHotkeyRegistrar()
        let settings = InMemorySettingsStore()
        let service = HotkeyService(
            registrar: registrar, settings: settings, readOccupied: { [] }, allowsRecording: false)
        return (service, registrar, settings)
    }

    @Test func aSetShortcutIsRegisteredAndCountsAsTheUsersChoice() throws {
        let (service, registrar, settings) = try service()
        service.setCommandShortcut("windows.workspace.2", KeyShortcut(key: "2", modifiers: [.control, .option]))
        let stored = try #require(registrar.shortcut(for: .command("windows.workspace.2")))
        #expect(stored.portable == KeyShortcut(key: "2", modifiers: [.control, .option]))
        // The default is never applied over it.
        let command = PluginCommand(
            id: "windows.workspace.2", title: "Go", defaultShortcut: KeyShortcut(key: "2", modifiers: [.option]))
        service.syncCommands([command], perform: { _ in })
        #expect(registrar.shortcut(for: .command("windows.workspace.2"))?.portable?.modifiers == [.control, .option])
        _ = settings
        service.setCommandShortcut("windows.workspace.2", nil)
        #expect(registrar.shortcut(for: .command("windows.workspace.2")) == nil)
    }

    @Test func aKeyLintelCannotMapIsIgnored() throws {
        let (service, registrar, _) = try service()
        service.setCommandShortcut("windows.x", KeyShortcut(key: "€", modifiers: [.option]))
        #expect(registrar.shortcut(for: .command("windows.x")) == nil)
    }

    @Test func thePortableFormRoundTrips() {
        for shortcut in [
            KeyShortcut(key: "1", modifiers: [.option]), KeyShortcut(key: "\t", modifiers: [.option]),
            KeyShortcut(key: "h", modifiers: [.control, .option, .shift, .command]),
        ] {
            #expect(HotkeyShortcut(shortcut)?.portable == shortcut)
        }
    }
}
