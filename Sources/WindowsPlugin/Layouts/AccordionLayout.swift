import CoreGraphics
import Foundation
import LintelKit

/// The frames of an Accordion workspace (pure geometry, no I/O). Every window takes the same area (after the outer
/// gap); the windows behind the focused one are pushed `padding` points along the orientation so that their edges
/// stick out on both sides, like AeroSpace's accordion.
///
/// The frames are chosen so that a change of focus moves as few windows as possible: the windows before the focused
/// one all have the same frame, so do the ones after it, and only the focused window has its own. Moving the focus
/// by one window therefore changes two frames (more only where the first or the last window gains or loses a
/// neighbour), which keeps a quick walk through nine windows far below the watchdog's limit.
enum AccordionLayout {
    /// How the windows are laid out along the axis.
    enum Orientation: String, Sendable, CaseIterable {
        case horizontal
        case vertical
    }

    /// The frames of `order` (join order); `focused` is the window in front (a window that is not in `order`
    /// counts as the first one).
    static func frames(
        order: [WindowID], focused: WindowID?, area: CGRect, gaps: TilingGaps, padding: CGFloat,
        orientation: Orientation
    ) -> [WindowID: CGRect] {
        guard !order.isEmpty else { return [:] }
        let dx = min(gaps.outer, area.width / 2)
        let dy = min(gaps.outer, area.height / 2)
        let inner = area.insetBy(dx: dx, dy: dy)
        let horizontal = orientation == .horizontal
        let length = horizontal ? inner.width : inner.height
        // The edges that stick out together never take more than half of the length.
        let peek = order.count > 1 ? max(0, min(padding, length / 4)).rounded() : 0
        let current = focused.flatMap { order.firstIndex(of: $0) } ?? 0
        let hasBefore = current > 0
        let hasAfter = current < order.count - 1
        let origin = horizontal ? inner.minX : inner.minY
        let end = origin + length
        // Along the axis: [start, end) of the windows in front, before and after the focused one.
        let core = (origin + (hasBefore ? peek : 0), end - (hasAfter ? peek : 0))
        let before = (origin, end - peek)
        let after = (origin + peek, end)

        func rect(_ span: (CGFloat, CGFloat)) -> CGRect {
            horizontal
                ? CGRect(x: span.0, y: inner.minY, width: max(0, span.1 - span.0), height: inner.height)
                : CGRect(x: inner.minX, y: span.0, width: inner.width, height: max(0, span.1 - span.0))
        }
        var result: [WindowID: CGRect] = [:]
        for (index, id) in order.enumerated() {
            result[id] = rect(index == current ? core : index < current ? before : after)
        }
        return result
    }
}

/// The state of an Accordion workspace: the windows in order (stored under the kind's name `accordion`).
struct AccordionState: LayoutStateValue, Equatable, Codable {
    var order: [WindowID]
    var isEmpty: Bool { order.isEmpty }
}

/// The global gaps an Accordion workspace uses (it has no gap options of its own: the ids belong to Auto-tile).
struct AccordionConfig: LayoutConfigValue, Equatable {
    var gaps: TilingGaps
}

/// Accordion: all windows of the workspace on top of each other, the others peeking out by the padding (state kind
/// `accordion`).
struct AccordionStrategy: LayoutStrategy {
    var kind: LayoutKind { .accordion }
    var displayName: String {
        String(localized: "Accordion", comment: "Window Management layout kind: windows overlap with edges showing")
    }

    static let paddingID = "accordionPadding"
    static let orientationID = "accordionOrientation"
    /// The orientation follows the shape of the display.
    static let autoOrientation = "auto"

    var options: [LayoutOption] {
        [
            LayoutOption(
                id: Self.paddingID,
                title: String(
                    localized: "Accordion padding",
                    comment: "Window Management setting: how far the windows behind the front one stick out"),
                domain: .points(WindowsSettings.accordionPaddingRange),
                defaultValue: .int(WindowsSettings.defaultAccordionPadding),
                settingKey: WindowsSettings.Key.accordionPadding),
            LayoutOption(
                id: Self.orientationID,
                title: String(
                    localized: "Accordion direction",
                    comment: "Window Management setting: the direction the accordion's edges stick out"),
                domain: .choices(
                    [
                        LayoutOption.Choice(
                            id: Self.autoOrientation,
                            title: String(
                                localized: "Automatic", comment: "Window Management: follows the display shape"))
                    ]
                        + AccordionLayout.Orientation.allCases.map {
                            LayoutOption.Choice(id: $0.rawValue, title: $0.displayName)
                        }),
                defaultValue: .string(Self.autoOrientation), settingKey: nil),
        ]
    }

    func summaryParts(_ resolved: ResolvedLayout) -> [String] {
        [
            String(
                localized: "Padding \(resolved.accordionPadding)",
                comment: "Window Management summary: accordion padding in points")
        ]
    }

    func makeConfig(_ environment: LayoutEnvironment) -> AnyLayoutConfig? {
        let settings = environment.settings
        let gaps = TilingStrategy().options.filter {
            [TilingStrategy.innerGapID, TilingStrategy.outerGapID].contains($0.id)
        }
        func points(_ id: String) -> CGFloat {
            guard let option = gaps.first(where: { $0.id == id }),
                case .int(let value) = settings.globalValue(of: option)
            else { return CGFloat(TilingStrategy.defaultGap) }
            return CGFloat(value)
        }
        return AnyLayoutConfig(
            AccordionConfig(
                gaps: TilingGaps(inner: points(TilingStrategy.innerGapID), outer: points(TilingStrategy.outerGapID))))
    }

    // MARK: Arranging

    func arrange(_ input: LayoutInput) -> LayoutArrangement {
        let wanted = Set(input.windows)
        var order = (input.state?.as(AccordionState.self)?.order ?? []).filter { wanted.contains($0) }
        // New windows enter after the focused window (or the one focused before it), several in join order.
        var anchor: WindowID?
        for id in input.windows where !order.contains(id) {
            if anchor == nil {
                anchor = [input.focused, input.previousFocus].lazy.compactMap { $0 }
                    .first { $0 != id && order.contains($0) }
            }
            if let anchor, let index = order.firstIndex(of: anchor) {
                order.insert(id, at: index + 1)
            } else {
                order.append(id)
            }
            anchor = id
        }
        let gaps =
            input.config?.as(AccordionConfig.self)?.gaps
            ?? TilingGaps(
                inner: CGFloat(TilingStrategy.defaultGap), outer: CGFloat(TilingStrategy.defaultGap))
        let frames = AccordionLayout.frames(
            order: order, focused: input.focused ?? input.previousFocus, area: input.area, gaps: gaps,
            padding: CGFloat(input.resolved.accordionPadding),
            orientation: input.resolved.accordionOrientation(for: input.area))
        return LayoutArrangement(
            state: AnyLayoutState(AccordionState(order: order)), frames: frames, hints: input.hints)
    }

    var arrangesOnFocusChange: Bool { true }

    // MARK: Commands

    func perform(_ command: LayoutCommand, on window: WindowID, _ input: LayoutInput) -> LayoutEdit? {
        guard let state = input.state?.as(AccordionState.self), let index = state.order.firstIndex(of: window),
            let direction = command.direction
        else { return nil }
        let orientation = input.resolved.accordionOrientation(for: input.area)
        let step: Int
        switch (orientation, direction) {
        case (.horizontal, .left), (.vertical, .up): step = -1
        case (.horizontal, .right), (.vertical, .down): step = 1
        default: return nil
        }
        let target = index + step
        guard state.order.indices.contains(target) else { return nil }
        switch command.id {
        case LayoutCommand.focusID:
            return LayoutEdit(state: AnyLayoutState(state), focus: state.order[target], hints: input.hints)
        case LayoutCommand.moveID:
            var next = state
            next.order.swapAt(index, target)
            return LayoutEdit(state: AnyLayoutState(next), focus: nil, hints: input.hints)
        default:
            return nil
        }
    }

    func removing(_ window: WindowID, from state: AnyLayoutState) -> AnyLayoutState {
        guard var value = state.as(AccordionState.self) else { return state }
        value.order.removeAll { $0 == window }
        return AnyLayoutState(value)
    }

    func encode(_ state: AnyLayoutState) -> JSONValue? {
        state.as(AccordionState.self).flatMap { JSONValue(encoding: $0) }
    }

    func decode(_ json: JSONValue) -> AnyLayoutState? {
        guard let value = json.decoded(as: AccordionState.self), !value.order.isEmpty else { return nil }
        return AnyLayoutState(value)
    }
}

extension AccordionLayout.Orientation {
    var displayName: String {
        switch self {
        case .horizontal:
            String(localized: "Horizontal", comment: "Window Management: accordion edges stick out left and right")
        case .vertical:
            String(localized: "Vertical", comment: "Window Management: accordion edges stick out above and below")
        }
    }
}

extension ResolvedLayout {
    /// The padding of an Accordion workspace in points.
    var accordionPadding: Int { int(AccordionStrategy.paddingID) ?? WindowsSettings.defaultAccordionPadding }

    /// The stored direction, with Auto made concrete by the shape of the display.
    func accordionOrientation(for area: CGRect) -> AccordionLayout.Orientation {
        if let text = string(AccordionStrategy.orientationID), let chosen = AccordionLayout.Orientation(rawValue: text)
        {
            return chosen
        }
        return area.width >= area.height ? .horizontal : .vertical
    }
}
