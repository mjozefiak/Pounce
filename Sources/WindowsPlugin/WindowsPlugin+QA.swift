#if DEBUG
import CoreGraphics
import Foundation
import LintelKit

/// The verbs of the QA command route that need an argument or reach past a command (`docs/qa.md`, "QA command
/// route"). DEBUG only; the route itself only exists in a `--qa` run. Every verb goes through the same runtime and
/// model entry points the UI uses.
extension WindowsPlugin: PluginQACommands {
    /// `state`, `resetState`, `restoreAll`, `snap <zone number>`, `import <path>`, `export <selected|all> <path>` (the rest of
    /// the line is the path), `addFloating <bundle id>`, `openLayouts`.
    public func runQACommand(_ line: String) async -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let verb = String(trimmed.prefix { $0 != " " })
        guard !verb.isEmpty else { return "error: empty" }
        // The argument is the rest of the line, so a path with spaces needs no quoting.
        var argument: String? = String(trimmed.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
        if argument?.isEmpty == true { argument = nil }
        switch verb {
        case "state":
            guard let runtime else { return "error: plugin is off" }
            return "ok: " + (await runtime.engine.inspect { Self.stateLine($0) })
        case "resetState":
            guard let runtime else { return "error: plugin is off" }
            await runtime.resetState()
            return "ok"
        case "restoreAll":
            await restoreAllWindows()
            return "ok"
        case "snap":
            return await qaSnap(zone: argument.flatMap(Int.init))
        case "stripRects":
            guard let rects = runtime?.strip?.boxScreenRects() else { return "error: the strip is not shown" }
            return "ok: "
                + rects.enumerated().map { index, rect in
                    "\(index + 1)=\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
                }.joined(separator: " ")
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
            // `export <selected|all> <path>`: the mode comes first, so a path may contain anything.
            guard let argument else { return "error: export needs a mode (selected or all) and a path" }
            let mode = String(argument.prefix { $0 != " " })
            let path = String(argument.dropFirst(mode.count)).trimmingCharacters(in: .whitespaces)
            let scope: LayoutsModel.ExportScope
            switch mode {
            case "selected": scope = .selected
            case "all": scope = .allMine
            default: return "error: unknown export mode \(mode) (use selected or all)"
            }
            guard !path.isEmpty else { return "error: export needs a path" }
            layoutsWindow.activatesApp = false
            layoutsWindow.show()
            guard let model = layoutsWindow.model else { return "error: the Layouts window did not open" }
            await model.refresh()
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

    /// What a QA run needs to see after a command: the current workspace, the window the engine counts as focused,
    /// which window is on which workspace and the focus counters. Window numbers only (no titles, no bundle ids).
    private nonisolated static func stateLine(_ state: EngineState) -> String {
        func name(_ id: WindowID) -> String { "\(id.pid).\(id.number)" }
        var parts = [
            "current=\(state.model.current.map { String($0.rawValue) } ?? "-")",
            "focused=\(state.focused.map(name) ?? "-")",
        ]
        for workspace in state.model.workspaces {
            let windows = state.model.windows(in: workspace)
            if !windows.isEmpty {
                parts.append("ws\(workspace.rawValue)=" + windows.map(name).joined(separator: ","))
            }
        }
        parts.append("parked=\(state.parked.count)")
        parts.append("focusMismatches=\(state.diagnostics.focusMismatches)")
        parts.append("focusReadTimeouts=\(state.diagnostics.focusReadTimeouts)")
        return parts.joined(separator: " ")
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
