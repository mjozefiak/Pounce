import Foundation
import LintelCore
import LintelKit

/// Putting parked windows back outside the running engine: *Restore all windows* without a runtime, erasing
/// data, and the recovery at launch (spec: Architecture, "Recovery runs outside the plugin lifecycle").
extension WindowsPlugin {
    /// *Restore all windows*: ends with the restore HUD. Without a running engine it works from the journal.
    func restoreAllWindows() async {
        if let runtime {
            await runtime.restoreAllWindows()
            return
        }
        switch await Self.restoreFromJournal(context: context) {
        case .ran(let report): hud.show(WindowsHUDState(report: report))
        case .engineRunning, .engineStopping: hud.show(.stillStopping)
        }
    }

    /// Why *Erase Data* refused: windows may still be parked, and the journal that can put them back lives in the
    /// folder the host would delete.
    public struct EraseRefused: LocalizedError, Equatable {
        public var errorDescription: String? {
            String(
                localized: "Windows are still parked, so their data was kept. Try again when they are back.",
                comment: "Window Management: Erase Data refused because windows are still hidden")
        }
    }

    /// How long *Erase Data* waits for an engine that is still stopping to hand the journal back.
    static let eraseBudget: Duration = .seconds(10)

    /// "Erase Data": puts every window back first and refuses (the host then keeps `Plugins/windows/`) while any
    /// window may still be parked: the engine has not handed the journal back, an app did not answer, or
    /// Accessibility is off. Only an empty journal is erased.
    public func eraseData() async throws {
        await deactivate()
        let journal = journal
        _ = await withDeadline(Self.eraseBudget, clock: context.clock) { await journal.waitUntilIdle() }
        guard case .ran(let report) = await Self.restoreFromJournal(context: context) else {
            context.logger.notice("Erase refused: the engine has not handed the journal back")
            throw EraseRefused()
        }
        if report.remaining > 0 || report.needsAccessibility {
            context.logger.notice("Erase refused: \(report.remaining, privacy: .public) windows not restored")
            throw EraseRefused()
        }
    }

    // MARK: Recovery

    /// Runs once per launch for every registered plugin, enabled or not (spec: Architecture, "Recovery runs
    /// outside the plugin lifecycle"): reads the journal and puts every parked window back. `.deferred` while
    /// Accessibility is not trusted, so the journal stays and the host tries again on app activation.
    public nonisolated static func recoverAtLaunch(context: PluginContext) async -> RecoveryOutcome {
        let journal = JournalOwner.owner(for: context)
        return await recover(context: context, hud: { await journal.reports.present($0) })
    }

    /// `recoverAtLaunch` with the registry and the HUD injected (tests). `isLaunch` is `nil` in the app: the
    /// journal owner counts the first pass of this process as the launch.
    nonisolated static func recover(
        context: PluginContext, isLaunch: Bool? = nil,
        hud: @Sendable (WindowsHUDState) async -> Void
    ) async -> RecoveryOutcome {
        let journal = JournalOwner.owner(for: context)
        let first: Bool
        if let isLaunch { first = isLaunch } else { first = await journal.claimLaunch() }
        // A running engine owns its journal: the windows parked in it are parked on purpose.
        let pass = await journal.exclusive { store in await restore(context: context, store: store) }
        let report: RecoveryReport
        switch pass {
        case .engineRunning: return .done
        case .engineStopping: return .deferred
        case .ran(let done): report = done
        }
        let settings = WindowsSettings(context.settings)
        if first, !report.readOnly {
            // A launch that found parked windows is counted; the second in a row starts the plugin in safe mode.
            if report.isEmpty {
                settings.setParkedLaunches(0)
            } else {
                settings.setParkedLaunches(settings.parkedLaunches + 1)
                if settings.parkedLaunches >= 2 { settings.setSafeMode(true) }
            }
        }
        if report.restored > 0 || (first && !report.isEmpty) {
            await hud(WindowsHUDState(report: report))
        }
        return report.outcome
    }

    /// One exclusive pass over the journal in `context.storageDirectory`, or who owns it instead (the caller says so
    /// instead of reporting an empty pass).
    nonisolated static func restoreFromJournal(
        context: PluginContext
    ) async -> JournalOwner.Pass<RecoveryReport> {
        let journal = JournalOwner.owner(for: context)
        return await journal.exclusive { store in await restore(context: context, store: store) }
    }

    private nonisolated static func restore(context: PluginContext, store: StateStore) async -> RecoveryReport {
        await store.load()
        guard await !store.hidden.isEmpty else { return RecoveryReport() }
        let trusted = await MainActor.run { context.permissions.status(of: .accessibility) == .granted }
        let report = await WindowRecovery.run(
            store: store, client: context.windows, trusted: trusted, logger: context.logger)
        await store.close()
        return report
    }
}
