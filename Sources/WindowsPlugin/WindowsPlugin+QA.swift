#if DEBUG
import CoreGraphics
import Foundation
import LintelKit

/// The verbs of the QA command route that need an argument or reach past a command (`docs/qa.md`, "QA command
/// route"). DEBUG only; the route itself only exists in a `--qa` run. Every verb goes through the same runtime and
/// model entry points the UI uses.
extension WindowsPlugin: PluginQACommands {
    /// `resetState`, `restoreAll`, `snap <zone number>`, `import <path>`, `export <path> [selected|all]` (the rest of the line is the path),
    /// `addFloating <bundle id>`, `openLayouts`.
    public func runQACommand(_ line: String) async -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let verb = String(trimmed.prefix { $0 != " " })
        guard !verb.isEmpty else { return "error: empty" }
        // The argument is the rest of the line, so a path with spaces needs no quoting.
        var argument: String? = String(trimmed.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
        if argument?.isEmpty == true { argument = nil }
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
            // A trailing `selected` or `all` picks the scope; the rest is the path.
            var path = argument
            var scope = LayoutsModel.ExportScope.allMine
            for (word, picked) in [(" selected", LayoutsModel.ExportScope.selected), (" all", .allMine)]
            where path.hasSuffix(word) {
                path = String(path.dropLast(word.count))
                scope = picked
            }
            qaFiles.exportURL = URL(filePath: path)
            model.export(scope)
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
