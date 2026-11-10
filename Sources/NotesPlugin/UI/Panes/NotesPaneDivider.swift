import LintelUI
import SwiftUI

/// The 1 pt line between a side pane and the centre, with a wider invisible handle: drag to resize, double-click
/// to go back to the default width. The handle follows the pointer without any animation (a drag must never lag,
/// with or without Reduce Motion), and VoiceOver and the keyboard get an adjustable element that moves it by steps.
struct NotesPaneDivider: View {
    let model: NotesWorkspaceModel
    let pane: NotesPane
    @Environment(\.lintelTextSize) private var textSize
    /// The width when the drag began; `nil` between drags.
    @State private var start: CGFloat?

    private var label: Text {
        switch pane {
        case .explorer: Text("Explorer width", comment: "Accessibility label of the explorer's divider")
        case .inspector: Text("Inspector width", comment: "Accessibility label of the inspector's divider")
        }
    }

    var body: some View {
        LintelDivider(axis: .vertical)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(drag)
                    .onTapGesture(count: 2) {
                        model.resetPaneWidth(pane, textScale: textSize.scale)
                    }
                    .help(
                        Text(
                            "Drag to resize. Double-click to reset.",
                            comment: "Tooltip of a pane divider in the Notes section"))
            }
            .zIndex(1)
            .transaction { $0.animation = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(Text(verbatim: "\(Int(model.paneWidth(pane, textScale: textSize.scale).rounded()))"))
            .accessibilityAdjustableAction { direction in
                // The inspector is on the right, so its divider moves the other way round.
                let sign = pane == .explorer ? 1 : -1
                switch direction {
                case .increment: model.nudgePane(pane, by: sign, textScale: textSize.scale)
                case .decrement: model.nudgePane(pane, by: -sign, textScale: textSize.scale)
                @unknown default: break
                }
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let begin = start ?? model.paneWidth(pane, textScale: textSize.scale)
                start = begin
                model.dragPane(
                    pane, from: begin, translation: value.translation.width, textScale: textSize.scale)
            }
            .onEnded { _ in
                start = nil
                model.endPaneDrag(textScale: textSize.scale)
            }
    }
}
