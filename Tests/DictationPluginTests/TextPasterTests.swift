import Foundation
import PounceKit
import Synchronization
import Testing
import os

@testable import DictationPlugin

/// A clock whose sleeps return at once and may run a closure, so a test can act "during" a wait.
final class HookClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let state = Mutex((now: Instant(offset: .zero), sleeps: [Duration]()))
    private let hook = Mutex<(@MainActor @Sendable (Duration) -> Void)?>(nil)

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    func onSleep(_ body: @escaping @MainActor @Sendable (Duration) -> Void) { hook.withLock { $0 = body } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let duration = state.withLock { state -> Duration in
            let wait = state.now.duration(to: deadline)
            state.sleeps.append(wait)
            state.now = deadline
            return wait
        }
        if let body = hook.withLock({ $0 }) {
            await MainActor.run { body(duration) }
        }
    }
}

/// Reads like `NamedPasteboard` but hides one type, as `readContents` does for data it cannot read.
@MainActor final class LossyPasteboard: PasteboardClient {
    let base: NamedPasteboard
    let hidden: String

    init(_ base: NamedPasteboard, hiding hidden: String) {
        self.base = base
        self.hidden = hidden
    }

    var changeCount: Int { base.changeCount }
    func string() -> String? { base.string() }
    func setString(_ string: String) -> Int { base.setString(string) }
    func types() -> [String] { base.types() }
    func itemTypes() -> [[String]] { base.itemTypes() }
    func write(_ items: [PasteboardItem]) -> Int { base.write(items) }
    var accessBehavior: PasteboardAccess { base.accessBehavior }

    func readContents(maxBytes: Int, including includes: (String) -> Bool) -> PasteboardContents? {
        base.readContents(maxBytes: maxBytes) { $0 != hidden && includes($0) }
    }
}

@MainActor
@Suite struct TextPasterTests {
    @MainActor final class Rig {
        let pasteboard = NamedPasteboard()
        let workspace = FakeWorkspace()
        let events = FakeEvents()
        let permissions = FakePermissions()
        let clock = HookClock()
        var restore = true
        var modifierPolls = 0
        var modifiersHeldFor = 0

        func paster(
            _ pasteboard: (any PasteboardClient)? = nil, ownBundleID: String? = "app.pounce.Pounce"
        ) -> TextPaster {
            TextPaster(
                pasteboard: pasteboard ?? self.pasteboard, events: events, workspace: workspace,
                permissions: permissions, clock: clock, restoresClipboard: { [unowned self] in restore },
                ownBundleID: ownBundleID,
                modifiersHeld: { [unowned self] in
                    modifierPolls += 1
                    defer { modifiersHeldFor = max(0, modifiersHeldFor - 1) }
                    return modifiersHeldFor > 0
                },
                logger: Logger(subsystem: "app.pounce.tests", category: "dictation"))
        }
    }

    @Test func pastesTheTextAndPutsTheOldClipboardBack() async {
        let rig = Rig()
        defer { rig.pasteboard.release() }
        rig.pasteboard.setString("what I copied before")
        let paster = rig.paster()

        #expect(await paster.paste("dictated text") == .pasted)
        #expect(rig.events.posts == 1)
        #expect(rig.pasteboard.string() == "dictated text")
        // The dictated text carries the transient marker, so the clipboard history skips it.
        #expect(rig.pasteboard.types().contains(PasteboardRepresentation.transientMarkerType))

        await paster.pendingRestore?.value
        #expect(rig.pasteboard.string() == "what I copied before")
        // The restore is marked transient as well and waited a second.
        #expect(rig.pasteboard.types().contains(PasteboardRepresentation.transientMarkerType))
        #expect(rig.clock.sleeps.contains(TextPaster.restoreDelay))
    }

    @Test func withoutAccessibilityTheTextIsOnlyCopiedAndNothingIsRestored() async {
        let rig = Rig()
        defer { rig.pasteboard.release() }
        rig.permissions.states[.accessibility] = .denied
        rig.pasteboard.setString("before")
        let paster = rig.paster()
        #expect(await paster.paste("dictated") == .copied(.noAccessibility))
        #expect(rig.events.posts == 0)
        #expect(paster.pendingRestore == nil)
        #expect(rig.pasteboard.string() == "dictated")
        // Nothing was read either: with no paste, the previous contents are not touched needlessly.
        #expect(rig.pasteboard.requestedTypes.isEmpty)
    }

    @Test func secureEventInputKeepsTheTextOnTheClipboard() async {
        let rig = Rig()
        defer { rig.pasteboard.release() }
        rig.events.error = .secureEventInput
        rig.pasteboard.setString("before")
        let paster = rig.paster()
        #expect(await paster.paste("password field") == .copied(.secureEventInput))
        #expect(paster.pendingRestore == nil)
        #expect(rig.pasteboard.string() == "password field")
    }

    @Test func aTargetThatQuitDuringTheWaitIsOnlyCopied() async {
        let rig = Rig()
        defer { rig.pasteboard.release() }
        rig.modifiersHeldFor = 2
        let workspace = rig.workspace
        rig.clock.onSleep { _ in workspace.running = [] }
        let paster = rig.paster()
        #expect(await paster.paste("text") == .copied(.targetGone))
        #expect(rig.events.posts == 0)
    }

    @Test func noFrontmostAppMeansCopyOnly() async {
        let rig = Rig()
        defer { rig.pasteboard.release() }
        rig.workspace.frontmost = nil
        #expect(await rig.paster().paste("text") == .copied(.targetGone))
    }

    @Test func whenPounceItselfIsInFrontThereIsNoCommandV() async {
        let rig = Rig()
        defer { rig.pasteboard.release() }
        rig.workspace.frontmost = RunningApplication(
            processIdentifier: 99, bundleIdentifier: "app.pounce.Pounce", name: "Pounce")
        #expect(await rig.paster().paste("text") == .copied(.ownApp))
        #expect(rig.events.posts == 0)
    }

    @Test func aCopyDuringTheWaitIsNeverOverwrittenByTheRestore() async {
        let rig = Rig()
        defer { rig.pasteboard.release() }
        rig.pasteboard.setString("before")
        let paster = rig.paster()
        await paster.paste("dictated")
        rig.pasteboard.setString("copied meanwhile")
        await paster.pendingRestore?.value
        #expect(rig.pasteboard.string() == "copied meanwhile")
    }

    @Test func anIncompleteReadMeansNoRestore() async {
        let rig = Rig()
        defer { rig.pasteboard.release() }
        rig.pasteboard.writeTypes([
            "public.utf8-plain-text": Data("before".utf8), "com.example.promised": Data("x".utf8),
        ])
        let lossy = LossyPasteboard(rig.pasteboard, hiding: "com.example.promised")
        let paster = rig.paster(lossy)
        #expect(await paster.paste("dictated") == .pasted)
        #expect(paster.pendingRestore == nil)
        #expect(rig.pasteboard.string() == "dictated")
    }

    @Test(arguments: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"])
    func aMarkedClipboardIsNeitherReadNorRestored(marker: String) async {
        let rig = Rig()
        defer { rig.pasteboard.release() }
        rig.pasteboard.writeTypes(["public.utf8-plain-text": Data("hunter2".utf8), marker: Data()])
        let paster = rig.paster()
        #expect(await paster.paste("dictated") == .pasted)
        #expect(rig.pasteboard.requestedTypes.isEmpty)
        #expect(paster.pendingRestore == nil)
        #expect(rig.pasteboard.string() == "dictated")
    }

    @Test(arguments: [PasteboardAccess.ask, .alwaysDeny, .systemDefault])
    func withoutPasteboardAccessNothingIsRead(access: PasteboardAccess) async {
        let rig = Rig()
        defer { rig.pasteboard.release() }
        rig.pasteboard.access = access
        rig.pasteboard.setString("before")
        let paster = rig.paster()
        #expect(await paster.paste("dictated") == .pasted)
        #expect(rig.pasteboard.requestedTypes.isEmpty)
        #expect(paster.pendingRestore == nil)
    }

    @Test func restoringCanBeTurnedOff() async {
        let rig = Rig()
        defer { rig.pasteboard.release() }
        rig.restore = false
        rig.pasteboard.setString("before")
        let paster = rig.paster()
        #expect(await paster.paste("dictated") == .pasted)
        #expect(paster.pendingRestore == nil)
        #expect(rig.pasteboard.string() == "dictated")
    }

    @Test func itWaitsForTheShortcutsKeysAndPastesAnywayAfterHalfASecond() async {
        let rig = Rig()
        defer { rig.pasteboard.release() }
        rig.modifiersHeldFor = 3
        let quick = rig.paster()
        #expect(await quick.paste("a") == .pasted)
        #expect(rig.modifierPolls == 4)

        let stuck = Rig()
        defer { stuck.pasteboard.release() }
        stuck.modifiersHeldFor = .max
        #expect(await stuck.paster().paste("b") == .pasted)
        #expect(stuck.clock.sleeps.reduce(.zero, +) >= TextPaster.modifierTimeout)
        #expect(stuck.events.posts == 1)
    }
}
