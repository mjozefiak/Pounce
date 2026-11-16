import Foundation
import LintelCore
import LintelKit
import os

/// What puts windows back and forgets state: *Restore all windows*, *Reset state*, the restart after the watchdog
/// and the diagnostics text.
extension WindowsRuntime {
    /// *Restore all windows*: always ends with the restore HUD. Returns what was done.
    @discardableResult
    func restoreAllWindows() async -> RecoveryReport {
        trust.refresh()
        let engine = engine
        // Bounded: a hung app must not hold the button for ever; what is still parked is reported instead.
        var report: RecoveryReport
        if let done = await withDeadline(Self.restoreBudget, clock: context.clock, { await engine.restoreAllWindows() })
        {
            report = done
        } else {
            report = RecoveryReport(failed: await engine.parkedCount())
        }
        recoveredWindows += report.restored
        hud.show(WindowsHUDState(report: report))
        return report
    }

    /// *Reset state*: puts every window back first, then starts over: the stored membership and layouts (the disk
    /// first, then the running engine, whose reset writes its new membership and layouts over the cleared file) and
    /// the layout assignments. Every window joins the workspace shown on its display again. The journal is never
    /// forgotten (`StateStore.reset`): a window that is still parked, or parked after the restore, can always be
    /// put back; the restore HUD has said what is still parked.
    func resetState() async {
        await restoreAllWindows()
        do { try await store.reset() } catch { context.logger.error("Cannot reset state.json") }
        do { try await assignments.reset() } catch { context.logger.error("Cannot reset assignments.json") }
        await engine.send(.resetState)
        await applySettings()
    }

    /// Clears the engine's frozen state (after the watchdog) by showing the current workspace again.
    func startAgain() async {
        engineBanner = nil
        if let target = lastSummary?.current ?? WorkspaceID.all(count: 1).first {
            await run(.showWorkspace(target), purpose: .switching)
        }
        context.resultsChanged()
    }

    func diagnosticsText() async -> String {
        let diagnostics = await engine.diagnostics()
        return WindowsDiagnostics.report(
            diagnostics, recoveredWindows: recoveredWindows, parkedWindows: await engine.parkedCount(),
            workspaceCount: settings.workspaceCount, accessibilityTrusted: trust.isTrusted)
    }

}
