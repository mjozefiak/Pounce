import CoreGraphics

/// The widths of the explorer and the inspector (owner feedback: drag the dividers). The numbers come from
/// `NotesPaneLayout`; this is the state: the stored width (`plugins.notes.explorerWidth` / `inspectorWidth`, written
/// when a drag ends) and the width of a drag in progress, which is never stored.
extension NotesWorkspaceModel {
    /// What the user dragged the pane to, or `nil` for the default.
    func storedPaneWidth(_ pane: NotesPane) -> CGFloat? {
        switch pane {
        case .explorer: NotesPaneLayout.stored(preferences.explorerWidth)
        case .inspector: NotesPaneLayout.stored(preferences.inspectorWidth)
        }
    }

    /// The pane's width before any limit: the stored width, else the width the section always had.
    func desiredPaneWidth(_ pane: NotesPane) -> CGFloat {
        storedPaneWidth(pane) ?? (pane == .explorer ? Self.explorerWidth : Self.inspectorWidth)
    }

    /// Whether the inspector sits next to the document (and takes room from it), as opposed to hidden or floating
    /// over its right edge in a narrow section.
    private var inspectorTakesRoom: Bool {
        inspectorVisible && inspectorFits && currentDocument?.phase == .loaded
    }

    /// What the pane may not take: the width of the pane beside the centre and the room the centre keeps.
    private func limits(_ pane: NotesPane, textScale: CGFloat) -> (other: CGFloat, reserve: CGFloat) {
        switch pane {
        case .explorer:
            return (
                inspectorTakesRoom ? desiredPaneWidth(.inspector) : 0,
                NotesPaneLayout.centreReserve(textScale: textScale)
            )
        case .inspector:
            // A floating inspector lies over the document and only has to leave the explorer and a sliver.
            return (
                desiredPaneWidth(.explorer),
                inspectorFits ? NotesPaneLayout.centreReserve(textScale: textScale) : 160
            )
        }
    }

    /// The width to draw for a pane: a drag in progress, else the stored or default one, kept inside the limits
    /// and the room the section has.
    func paneWidth(_ pane: NotesPane, textScale: CGFloat) -> CGFloat {
        let limit = limits(pane, textScale: textScale)
        let stored = paneDrag?.pane == pane ? paneDrag?.width : storedPaneWidth(pane)
        return NotesPaneLayout.effectiveWidth(
            pane, stored: stored, textScale: textScale, sectionWidth: sectionWidth, otherWidth: limit.other,
            reserve: limit.reserve)
    }

    /// A drag of the divider is at `translation` points from where it began (`start` is the width then). Nothing
    /// is stored until `endPaneDrag`.
    func dragPane(_ pane: NotesPane, from start: CGFloat, translation: CGFloat, textScale: CGFloat) {
        paneDrag = (pane, NotesPaneLayout.dragged(from: start, translation: translation, pane: pane))
        // The same limits as the final width, so the divider never runs ahead of the pane.
        paneDrag = (pane, paneWidth(pane, textScale: textScale))
    }

    /// The drag ended: the width shown becomes the stored one.
    func endPaneDrag(textScale: CGFloat) {
        guard let drag = paneDrag else { return }
        let width = paneWidth(drag.pane, textScale: textScale)
        paneDrag = nil
        setPaneWidth(drag.pane, to: width, textScale: textScale)
    }

    /// Stores a width (clamped).
    func setPaneWidth(_ pane: NotesPane, to width: CGFloat, textScale: CGFloat) {
        paneDrag = nil
        let limit = limits(pane, textScale: textScale)
        let kept = NotesPaneLayout.raw(
            NotesPaneLayout.clamp(
                width, pane: pane, textScale: textScale, sectionWidth: sectionWidth, otherWidth: limit.other,
                reserve: limit.reserve))
        switch pane {
        case .explorer: preferences.explorerWidth = kept
        case .inspector: preferences.inspectorWidth = kept
        }
        updateInspectorFit(sectionWidth: sectionWidth, textScale: textScale)
    }

    /// A double-click on the divider: back to the default width.
    func resetPaneWidth(_ pane: NotesPane, textScale: CGFloat) {
        paneDrag = nil
        switch pane {
        case .explorer: preferences.explorerWidth = 0
        case .inspector: preferences.inspectorWidth = 0
        }
        updateInspectorFit(sectionWidth: sectionWidth, textScale: textScale)
    }

    /// Keyboard and VoiceOver: a step wider (`+1`) or narrower (`-1`).
    func nudgePane(_ pane: NotesPane, by steps: Int, textScale: CGFloat) {
        let current = paneWidth(pane, textScale: textScale)
        setPaneWidth(pane, to: current + CGFloat(steps) * NotesPaneLayout.nudge, textScale: textScale)
    }
}
