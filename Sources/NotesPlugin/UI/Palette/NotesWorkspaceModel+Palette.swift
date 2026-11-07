import Foundation
import LintelKit

/// The palette's open state: what was typed and which line is selected.
struct PaletteState: Equatable {
    var query = ""
    var selection = 0
}

extension NotesWorkspaceModel {
    // MARK: Hide content (⌘⇧H)

    /// What a masked title shows.
    static let maskedTitle = "••••••"

    func toggleHideContent() {
        hidesContent.toggle()
        // A palette left open would list the titles the user just hid.
        if hidesContent { palette = nil }
    }

    /// A title as the screen may show it: masked while content is hidden.
    func shown(_ title: String) -> String { hidesContent ? Self.maskedTitle : title }

    /// The path bar's parts with the note's own title masked (the group and the layer name stay).
    func shownPath(_ parts: [String]) -> [String] {
        guard hidesContent, let id = tabs.current else { return parts }
        let title = row(for: id).map { presentation.pathTitle($0.summary) } ?? tabs.tabs.first { $0.id == id }?.title
        return parts.map { $0 == title ? Self.maskedTitle : $0 }
    }

    // MARK: Inspector width

    /// What the centre column needs next to the explorer and the inspector, in points at Medium; it grows with
    /// the text size, so at the largest size the inspector gives way first.
    static let centreMinimumWidth: CGFloat = NotesPaneLayout.centreMinimumWidth
    static let explorerWidth: CGFloat = 250
    static let inspectorWidth: CGFloat = 300

    /// `explorer` and `inspector` are the widths the user may have dragged the panes to (the defaults otherwise).
    static func inspectorFits(
        sectionWidth: CGFloat, textScale: CGFloat, explorer: CGFloat = explorerWidth,
        inspector: CGFloat = inspectorWidth
    ) -> Bool {
        sectionWidth >= explorer + inspector + centreMinimumWidth * max(textScale, 1)
    }

    /// Called by the section with its width: a narrow section hides the inspector (the path bar's button shows it
    /// over the document again) and a wide one brings back what it hid.
    func updateInspectorFit(sectionWidth: CGFloat, textScale: CGFloat) {
        self.sectionWidth = sectionWidth
        let fits = Self.inspectorFits(
            sectionWidth: sectionWidth, textScale: textScale, explorer: desiredPaneWidth(.explorer),
            inspector: desiredPaneWidth(.inspector))
        guard fits != inspectorFits else { return }
        inspectorFits = fits
        if !fits, inspectorVisible {
            inspectorVisible = false
            inspectorHiddenForWidth = true
        } else if fits, inspectorHiddenForWidth {
            inspectorVisible = true
            inspectorHiddenForWidth = false
        }
    }

    /// The user shows or hides the inspector by hand: a later resize no longer changes it.
    func setInspectorVisible(_ visible: Bool) {
        inspectorVisible = visible
        inspectorHiddenForWidth = false
    }

    // MARK: Command palette (⌘P)

    /// The commands offered after the notes: the shell's (other plugins' commands, Settings) and Hide/Show content.
    var paletteCommands: [PaletteCommand] {
        var commands = environment.availableCommands().map {
            PaletteCommand(
                title: String(localized: $0.title), detail: $0.shortcut.map(Self.display) ?? "",
                isEnabled: $0.isEnabled(),
                run: $0.run)
        }
        let hideTitle =
            hidesContent
            ? String(localized: "Show content", comment: "Command palette and menu: shows hidden content again")
            : String(localized: "Hide content", comment: "Command palette and menu: blurs the notes for screen sharing")
        commands.append(
            PaletteCommand(
                title: hideTitle, detail: Self.display(Self.hideContentShortcut), isEnabled: true,
                run: { [weak self] in self?.toggleHideContent() }))
        return commands.filter(\.isEnabled)
    }

    var paletteItems: [PaletteItem] {
        guard let palette else { return [] }
        let notes = rows.map { row in
            (
                id: row.id,
                candidate: PaletteCandidate(
                    title: title(of: row), detail: presentation.paletteDetail(row.summary, now: environment.now()))
            )
        }
        let commands = paletteCommands.map { PaletteCandidate(title: $0.title, detail: $0.detail) }
        return CommandPaletteEntries.build(notes: notes, commands: commands, query: palette.query)
    }

    func showPalette() {
        // The palette lists titles; while content is hidden there is nothing to go to by name.
        guard !hidesContent else { return }
        palette = PaletteState()
    }

    func hidePalette() { palette = nil }

    func togglePalette() {
        if palette == nil { showPalette() } else { hidePalette() }
    }

    func setPaletteQuery(_ query: String) {
        guard var state = palette else { return }
        state.query = query
        state.selection = 0
        palette = state
    }

    func movePaletteSelection(by delta: Int) {
        guard var state = palette else { return }
        let count = paletteItems.count
        guard count > 0 else { return }
        state.selection = (state.selection + delta + count) % count
        palette = state
    }

    /// Runs the selected line (or `item`): opens the note, or runs the command. The palette closes first.
    func runPalette(_ item: PaletteItem? = nil) {
        guard let state = palette else { return }
        let items = paletteItems
        guard let chosen = item ?? (items.indices.contains(state.selection) ? items[state.selection] : nil) else {
            return
        }
        let commands = paletteCommands
        palette = nil
        switch chosen.target {
        case .note(let id): open(id)
        case .command(let index): if commands.indices.contains(index) { commands[index].run() }
        }
    }

    static let hideContentShortcut = KeyShortcut(key: "h", modifiers: [.command, .shift])
    static let paletteShortcut = KeyShortcut(key: "p", modifiers: [.command])

    /// "⌘⇧H" as the prototype and the hint strip write it: control, option, command, shift, then the key.
    static func display(_ shortcut: KeyShortcut) -> String {
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "⌃" }
        if shortcut.modifiers.contains(.option) { text += "⌥" }
        if shortcut.modifiers.contains(.command) { text += "⌘" }
        if shortcut.modifiers.contains(.shift) { text += "⇧" }
        switch shortcut.key {
        case " ": return text + String(localized: "Space", comment: "Name of the space bar in a shortcut")
        case "\r": return text + "↩"
        default: return text + shortcut.key.uppercased()
        }
    }
}

/// A command as the palette runs it.
struct PaletteCommand {
    var title: String
    var detail: String
    var isEnabled: Bool
    var run: @MainActor () -> Void
}
