import Foundation
import Testing

@testable import LintelApp

private let appSources = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Sources/LintelApp", directoryHint: .isDirectory)

/// ADR 0008, "Release gate": since step 6.3a the window is enabled in every build. These source scans fail when the
/// main window, its router, its menu or the routes into it go back behind `#if DEBUG`, while the QA launch arguments
/// stay DEBUG-only.
@Suite struct ReleaseGateTests {
    /// The lines of `source` that a release build does not compile: inside an `#if DEBUG` branch (or the `#else` of
    /// an `#if !DEBUG`), nested conditions included.
    static func debugOnlyLines(_ source: String) -> [String] {
        // One entry per open `#if`: its condition and whether its current branch is DEBUG-only.
        var stack: [(condition: String, isDebugOnly: Bool)] = []
        var lines: [String] = []
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") {
                let condition = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                stack.append((condition, condition == "DEBUG"))
            } else if line.hasPrefix("#elseif"), let last = stack.popLast() {
                stack.append((last.condition, false))
            } else if line == "#else", let last = stack.popLast() {
                stack.append((last.condition, last.condition == "!DEBUG"))
            } else if line == "#endif" {
                _ = stack.popLast()
            } else if stack.contains(where: \.isDebugOnly) {
                lines.append(line)
            }
        }
        return lines
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: appSources.appending(path: path), encoding: .utf8)
    }

    @Test func theScannerFindsDebugOnlyLines() {
        let source = """
            let a = 1
            #if DEBUG
            let b = 2
            #else
            let c = 3
            #endif
            #if os(macOS)
            let d = 4
            #endif
            #if !DEBUG
            let e = 5
            #else
            let f = 6
            #endif
            """
        #expect(Self.debugOnlyLines(source) == ["let b = 2", "let f = 6"])
    }

    @Test func theMainWindowTypesAreCompiledInEveryBuild() throws {
        let files = [
            "Window/MainWindowController.swift": "final class MainWindowController",
            "Window/MainWindowRouter.swift": "final class MainWindowRouter",
            "Window/MainMenuController.swift": "final class MainMenuController",
            "Window/MainMenuPolicy.swift": "MainMenuPolicy",
            "Window/MainWindowState.swift": "MainWindowState",
        ]
        for (path, declaration) in files {
            let text = try source(path)
            #expect(text.contains(declaration), "\(path) no longer declares \(declaration)")
            #expect(!text.contains("#if DEBUG"), "\(path) is behind #if DEBUG again")
        }
        #expect(!(try source("Window/MainWindowRouter.swift")).contains("isWindowEnabled"))
    }

    @Test func theCoordinatorBuildsAndRoutesToTheMainWindowInEveryBuild() throws {
        let debugOnly = Self.debugOnlyLines(try source("AppCoordinator.swift")).joined(separator: "\n")
        for needle in [
            "var mainWindow: MainWindowController?", "var mainMenu: MainMenuController?",
            "func makeMainWindow()", "func makeRouter()", "func showMainWindow(", "func settingsModeContent(",
            "func modelsPaneModel()", "func mainWindowPluginPanes()", "targets.showMainWindow",
            "router.openSettings", "router.openModels", "OnboardingController(",
        ] {
            #expect(!debugOnly.contains(needle), "\(needle) is DEBUG-only")
        }
        #expect(debugOnly.contains("func showMainWindowForQA("), "the --qa-window entry point stays DEBUG-only")
        #expect(debugOnly.contains("func showOnboardingStepForQA("), "--qa-onboarding-step stays DEBUG-only")
    }

    @Test func theDockReopenGoesToTheRouterInEveryBuild() throws {
        let debugOnly = Self.debugOnlyLines(try source("LintelMain.swift")).joined(separator: "\n")
        #expect(!debugOnly.contains("coordinator?.reopen()"))
        #expect(debugOnly.contains("QAOptions.parse"), "the QA launch arguments stay DEBUG-only")
    }

    @Test func theQAOptionsStayDebugOnly() throws {
        let text = try source("QA/QAOptions.swift")
        #expect(text.hasPrefix("#if DEBUG") || text.contains("\n#if DEBUG"))
    }

    @Test func theKeptCopiesOptionStaysDebugOnlyUntilNotesShips() throws {
        // Spec B step 7.1 removes this guard, not 6.3a.
        let debugOnly = Self.debugOnlyLines(try source("Settings/FeaturesPane.swift")).joined(separator: "\n")
        #expect(debugOnly.contains("keptNotesCopies"))
    }
}
