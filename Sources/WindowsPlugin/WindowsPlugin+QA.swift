#if DEBUG
import CoreGraphics
import Foundation
import LintelKit

/// The verbs of the QA command route that need an argument or reach past a command (`docs/qa.md`, "QA command
/// route"). DEBUG only; the route itself only exists in a `--qa` run. Every verb goes through the same runtime and
/// model entry points the UI uses.
extension WindowsPlugin: PluginQACommands {
    /// `resetState`, `restoreAll`, `snap <zone number>`, `import <path>`, `export <path> [selected|all]`,
    /// `addFloating <bundle id>`, `openLayouts`.
    public func runQACommand(_ line: String) async -> String {
        let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let verb = words.first else { return "error: empty" }
        let argument = words.dropFirst().first
        switch verb {
        case "resetState":
            guard let runtime else { return "error: plugin is off" }
            await runtime.resetState()
            return "ok"
        case "restoreAll":
            await restoreAllWindows()
            return "ok"
        case "snap":
            return await qaSnap(zone: argument.flatMap(Int.init))
        case "openLayouts":
            layoutsWindow.activatesApp = false
            layoutsWindow.show()
            return "ok"
        case "import":
            guard let argument else { return "error: import needs a path" }
            layoutsWindow.activatesApp = false
            layoutsWindow.show()
            guard let model = layoutsWindow.model else { return "error: the Layouts window did not open" }
            await model.refresh()
            qaFiles.importURL = URL(filePath: argument)
            model.beginImport()
            guard model.pendingImport != nil else { return "error: \(model.notice ?? "nothing to import")" }
            await model.confirmImport()
            return "ok"
        case "export":
            guard let argument else { return "error: export needs a path" }
            layoutsWindow.activatesApp = false
            layoutsWindow.show()
            guard let model = layoutsWindow.model else { return "error: the Layouts window did not open" }
            await model.refresh()
            qaFiles.exportURL = URL(filePath: argument)
            model.export(words.dropFirst(2).first == "selected" ? .selected : .allMine)
            return model.notice.map { "ok: \($0)" } ?? "ok"
        case "addFloating":
            guard let argument else { return "error: addFloating needs a bundle id" }
            qaFiles.appPicker.set(argument)
            paneModel.addFloatingApp()
            return "ok"
        default:
            return "error: unknown verb \(verb)"
        }
    }

    /// Snaps the focused window to zone `number` of the layout it sits in, as a drag released over it would.
    private func qaSnap(zone number: Int?) async -> String {
        guard let runtime, let number else { return "error: snap needs a zone number and the plugin on" }
        guard let window = await context.windows.focusedWindow() else { return "error: no focused window" }
        let displays = await runtime.engine.dragDisplays(for: window)
        guard let zone = displays.flatMap(\.zones).first(where: { $0.number == number }) else {
            return "error: no zone \(number) offered for the focused window"
        }
        await runtime.snap(window, to: zone)
        return "ok"
    }
}
#endif
