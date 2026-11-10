import CoreGraphics

/// A side pane of the Notes section that has a draggable divider.
enum NotesPane: CaseIterable, Sendable {
    /// The explorer on the left; its divider is on its right edge.
    case explorer
    /// The inspector on the right; its divider is on its left edge.
    case inspector
}

/// The widths of the side panes as pure functions (owner feedback: the panes were fixed). Nothing here knows a
/// view, a window or a setting, so the clamping is tested on its own.
///
/// A stored width is in points as the user dragged it; `nil` (stored as 0) means "the default", which scales with
/// the text size and is capped, as the fixed widths were before.
enum NotesPaneLayout {
    /// The smallest a pane may be, in points (shrinks with a text size below Medium, never grows).
    static func minimumWidth(_ pane: NotesPane, textScale: CGFloat) -> CGFloat {
        base(pane).minimum * min(max(textScale, 0.5), 1)
    }

    /// The widest a pane may be, whatever the room.
    static func maximumWidth(_ pane: NotesPane) -> CGFloat { base(pane).maximum }

    /// What a pane measures before the user drags it: the width the section always had.
    static func defaultWidth(_ pane: NotesPane, textScale: CGFloat) -> CGFloat {
        min(base(pane).factor * 12.5 * textScale, base(pane).cap)
    }

    /// What the centre column needs at Medium (`NotesWorkspaceModel.centreMinimumWidth` is this value).
    static let centreMinimumWidth: CGFloat = 420

    /// The room the centre column keeps at least, in points; grows with the text size like the one in
    /// `NotesWorkspaceModel.inspectorFits`.
    static func centreReserve(textScale: CGFloat) -> CGFloat {
        centreMinimumWidth * max(textScale, 1)
    }

    /// Keeps a requested width between the pane's minimum and the smaller of its maximum and what the section can
    /// give it: `sectionWidth` minus `otherWidth` (the pane beside the centre, 0 when it is hidden or floats over
    /// the document) minus `reserve` for the centre. The minimum always wins, so a section that is too narrow
    /// never makes a pane unusably thin. A non-finite request gives the default.
    static func clamp(
        _ width: CGFloat, pane: NotesPane, textScale: CGFloat, sectionWidth: CGFloat, otherWidth: CGFloat,
        reserve: CGFloat
    ) -> CGFloat {
        guard width.isFinite else { return defaultWidth(pane, textScale: textScale) }
        let low = minimumWidth(pane, textScale: textScale)
        let room = sectionWidth - otherWidth - reserve
        let high = max(low, min(maximumWidth(pane), room.isNaN ? maximumWidth(pane) : room))
        return min(max(width, low), high)
    }

    /// The width to draw: the stored one, or the default, kept inside the limits.
    static func effectiveWidth(
        _ pane: NotesPane, stored: CGFloat?, textScale: CGFloat, sectionWidth: CGFloat, otherWidth: CGFloat,
        reserve: CGFloat
    ) -> CGFloat {
        clamp(
            stored ?? defaultWidth(pane, textScale: textScale), pane: pane, textScale: textScale,
            sectionWidth: sectionWidth, otherWidth: otherWidth, reserve: reserve)
    }

    /// The width after a drag of `translation` points to the right (negative: to the left) from `start`. The
    /// inspector's divider is on its left edge, so dragging right makes it narrower.
    static func dragged(from start: CGFloat, translation: CGFloat, pane: NotesPane) -> CGFloat {
        switch pane {
        case .explorer: start + translation
        case .inspector: start - translation
        }
    }

    /// What a keyboard or VoiceOver nudge (adjustable divider) changes a width by.
    static let nudge: CGFloat = 16

    /// A stored integer (0 or less: not set) as a width.
    static func stored(_ raw: Int) -> CGFloat? { raw > 0 ? CGFloat(raw) : nil }

    /// A width as the integer that is stored (whole points).
    static func raw(_ width: CGFloat) -> Int { width.isFinite ? max(Int(width.rounded()), 0) : 0 }

    private struct Base {
        var factor: CGFloat
        var cap: CGFloat
        var minimum: CGFloat
        var maximum: CGFloat
    }

    /// The default is `factor` em of 12.5 pt (the old `19 * 12.5` and `23 * 12.5`), capped at `cap`.
    private static func base(_ pane: NotesPane) -> Base {
        switch pane {
        case .explorer: Base(factor: 19, cap: 250, minimum: 180, maximum: 420)
        case .inspector: Base(factor: 23, cap: 300, minimum: 240, maximum: 520)
        }
    }
}
