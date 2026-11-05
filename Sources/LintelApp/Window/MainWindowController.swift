import AppKit
import LintelKit
import LintelUI
import SwiftUI

/// The main window (spec `2026-11-04-lintel-main-window`): one `NSWindow` with SwiftUI content in two modes,
/// Workspace (a plugin's `WorkspaceSection`) and Settings (a pane). Built once and reused; it restores its mode,
/// section and pane from `MainWindowState` and its frame from AppKit frame autosave (`MainWindow`).
///
/// Behind the release gate of ADR 0008 until step 6.3: only DEBUG builds create it (`--qa-window`).
final class MainWindowController {
    static let autosaveName = "MainWindow"
    static let minimumSize = NSSize(width: 880, height: 560)
    static let defaultSize = NSSize(width: 1180, height: 720)

    private let settings: any SettingsStore
    private let sections: () -> [WorkspaceSection]
    private let settingsPanes: () -> [String]
    private let screens: () -> [NSRect]
    private let frameAutosaveName: String?
    private let makeContent: (MainWindowState, [WorkspaceSection]) -> AnyView
    private var hosting: NSHostingController<AnyView>?
    /// The pending close (Command-W or the title bar's close button) while the section's `willHide` runs.
    private var closeTask: Task<Void, Never>?
    /// Bumped by every change of state and every presentation, so a pending close or mode switch that waited on
    /// `willHide` does nothing when the window was reopened or switched meanwhile.
    private var generation = 0

    private(set) var window: NSWindow?
    private(set) var state: MainWindowState?

    /// Called after the state changed (mode, section or pane), so the main menu can follow.
    var onChange: (() -> Void)?

    /// False in QA mode: the window is ordered front without activating Lintel.
    var activatesApp = true
    /// The app's text size (`app.textSize`), read while the content renders so a change applies at once.
    var textSize: () -> TextSize = { .default }

    /// - Parameters:
    ///   - settings: where the mode, section and pane are stored.
    ///   - sections: the active plugins' workspace sections, in order.
    ///   - settingsPanes: the ids of the panes Settings mode can show.
    ///   - screens: the screens' visible frames, main screen first (injected for tests).
    ///   - frameAutosaveName: `nil` in QA mode and tests, so the frame never reaches the user's defaults.
    ///   - makeContent: the window content for a state (step 1.3 hosts the Settings panes here).
    init(
        settings: any SettingsStore,
        sections: @escaping () -> [WorkspaceSection],
        settingsPanes: @escaping () -> [String],
        screens: @escaping () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) },
        frameAutosaveName: String? = MainWindowController.autosaveName,
        makeContent: @escaping (MainWindowState, [WorkspaceSection]) -> AnyView
    ) {
        self.settings = settings
        self.sections = sections
        self.settingsPanes = settingsPanes
        self.screens = screens
        self.frameAutosaveName = frameAutosaveName
        self.makeContent = makeContent
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Opens the window in the restored state.
    ///
    /// Every change that leaves the visible Workspace section (another mode or section) first awaits that
    /// section's `willHide`; the returned task is that pending change, `nil` when it applied at once.
    @discardableResult
    func show() -> Task<Void, Never>? {
        transition(to: restoredState(), presenting: true)
    }

    /// Opens Workspace mode on a section (the stored or first one for `nil`); without any section, Settings mode.
    @discardableResult
    func showWorkspace(_ sectionID: String? = nil) -> Task<Void, Never>? {
        var state = restoredState()
        let ids = sections().map(\.id)
        if let first = ids.first {
            state.mode = .workspace
            state.section = sectionID.flatMap { ids.contains($0) ? $0 : nil } ?? state.section ?? first
        } else {
            state.mode = .settings
        }
        return transition(to: state, presenting: true)
    }

    /// Opens Settings mode on a pane (the stored one for `nil`); an unknown id opens General.
    @discardableResult
    func showSettings(_ paneID: String? = nil) -> Task<Void, Never>? {
        var state = restoredState()
        state.mode = .settings
        if let paneID {
            state.settingsPane = settingsPanes().contains(paneID) ? paneID : MainWindowState.defaultSettingsPane
        }
        return transition(to: state, presenting: true)
    }

    /// Selects a Settings pane while the window is open (the adapter's list calls this); an unknown id is ignored.
    @discardableResult
    func selectSettingsPane(_ paneID: String) -> Task<Void, Never>? {
        guard var state, settingsPanes().contains(paneID) else { return nil }
        state.settingsPane = paneID
        return transition(to: state, presenting: false)
    }

    func close() {
        window?.close()
    }

    /// The active workspace section in Workspace mode, `nil` in Settings mode.
    var activeSection: WorkspaceSection? {
        guard state?.mode == .workspace else { return nil }
        return sections().first { $0.id == state?.section }
    }

    /// Command-W. In Workspace mode the section is asked first (`handleClose`: it may close a tab itself and keep
    /// the window open), then the window closes after the section's `willHide`. Returns the pending close; a
    /// second Command-W while it waits returns the same task.
    @discardableResult
    func requestClose() -> Task<Void, Never>? {
        guard let window else { return nil }
        if let closeTask { return closeTask }
        guard let section = visibleSection else {
            window.close()
            return nil
        }
        if section.handleClose() { return nil }
        return hideThenClose(section)
    }

    /// The app is quitting: awaits the visible section's `willHide` (`applicationShouldTerminate` replies later).
    func prepareForTermination() async {
        if let closeTask {
            await closeTask.value
            return
        }
        guard let section = visibleSection else { return }
        generation += 1
        await section.willHide()
    }

    /// The title bar's close button: like Command-W without asking `handleClose` (it closes the window, not a
    /// tab). `false` keeps the window open until `willHide` finished.
    private func windowShouldClose() -> Bool {
        guard closeTask == nil else { return false }
        guard let section = visibleSection else { return true }
        hideThenClose(section)
        return false
    }

    /// The active section while the window is on screen; a hidden window's section was already told.
    private var visibleSection: WorkspaceSection? {
        guard isVisible else { return nil }
        return activeSection
    }

    @discardableResult
    private func hideThenClose(_ section: WorkspaceSection) -> Task<Void, Never> {
        let expected = generation
        let task = Task { @MainActor [weak self] in
            await section.willHide()
            guard let self else { return }
            self.closeTask = nil
            guard self.generation == expected else { return }
            self.window?.close()
        }
        closeTask = task
        return task
    }

    /// Applies `state`, first awaiting `willHide` of the visible section it leaves. A later change or a reopen
    /// while that runs wins.
    private func transition(to state: MainWindowState, presenting: Bool) -> Task<Void, Never>? {
        let leaving = visibleSection.flatMap { section in
            state.mode != .workspace || state.section != section.id ? section : nil
        }
        guard let leaving else {
            apply(state)
            if presenting { present() }
            return nil
        }
        generation += 1
        closeTask = nil
        let expected = generation
        return Task { @MainActor [weak self] in
            await leaving.willHide()
            guard let self, self.generation == expected else { return }
            self.apply(state)
            if presenting { self.present() }
        }
    }

    private func restoredState() -> MainWindowState {
        MainWindowState.restore(
            from: settings, sections: sections().map(\.id), settingsPanes: settingsPanes())
    }

    private func apply(_ state: MainWindowState) {
        generation += 1
        self.state = state
        state.save(to: settings)
        defer { onChange?() }
        let content = LintelTextSizeScope(size: textSize) { makeContent(state, sections()) }
            .environment(\.settingsHostStyle, .mainWindow)
            .buttonStyle(LintelSecondaryButtonStyle())
            .lintelBrand()
        if let hosting {
            hosting.rootView = AnyView(content)
            if let window { Self.applyChrome(to: window, mode: state.mode) }
        } else {
            build(AnyView(content), mode: state.mode)
        }
    }

    /// Settings mode has the prototype's chrome: a transparent title bar without a title, the traffic lights over
    /// the full-height sidebar. Workspace mode keeps the standard title bar until its sections draw their own.
    /// The title stays set for the Window menu and VoiceOver.
    static func applyChrome(to window: NSWindow, mode: MainWindowState.Mode) {
        let fullHeight = mode == .settings
        if fullHeight {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
        window.titlebarAppearsTransparent = fullHeight
        window.titleVisibility = fullHeight ? .hidden : .visible
        window.titlebarSeparatorStyle = fullHeight ? .none : .automatic
    }

    private func build(_ content: AnyView, mode: MainWindowState.Mode) {
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        let window = ShellWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Lintel"
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minimumSize
        // Before the size: in Settings mode the content runs under the title bar, so the default size is the
        // whole window, as the prototype draws it.
        Self.applyChrome(to: window, mode: mode)
        window.setContentSize(Self.defaultSize)
        // AppKit's own restoration would reopen the window at launch, outside the release gate.
        window.isRestorable = false
        var isRestored = false
        if let frameAutosaveName {
            isRestored = window.setFrameUsingName(frameAutosaveName)
            window.setFrameAutosaveName(frameAutosaveName)
        }
        let frame = Self.validatedFrame(window.frame, screens: screens(), isRestored: isRestored)
        window.setFrame(frame, display: false)
        window.closeHandler = { [weak self] in
            self?.requestClose()
            return true
        }
        window.shouldClose = { [weak self] in self?.windowShouldClose() ?? true }
        self.window = window
        self.hosting = hosting
    }

    private func present() {
        guard let window else { return }
        generation += 1
        if activatesApp {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    /// The smallest part of a frame that must lie on a screen for the window to count as on screen.
    static let minimumVisiblePart = NSSize(width: 100, height: 50)

    /// Keeps a frame that is on a screen; a frame outside every screen (a disconnected display, an older layout)
    /// is centered on the main screen, shrunk to fit it. A frame that was not restored is always centered.
    ///
    /// - Parameter screens: the screens' visible frames, main screen first.
    static func validatedFrame(_ frame: NSRect, screens: [NSRect], isRestored: Bool = true) -> NSRect {
        let isOnScreen = screens.contains { screen in
            let visible = frame.intersection(screen)
            return !visible.isNull && visible.width >= minimumVisiblePart.width
                && visible.height >= minimumVisiblePart.height
        }
        if isRestored, isOnScreen { return frame }
        guard let main = screens.first else { return frame }
        let size = NSSize(width: min(frame.width, main.width), height: min(frame.height, main.height))
        return NSRect(
            x: (main.midX - size.width / 2).rounded(), y: (main.midY - size.height / 2).rounded(),
            width: size.width, height: size.height)
    }
}
