import LintelUI
import SwiftUI

/// A small drawing of a layout (mockup 05): its zones as rounded rectangles in the accent. Decorative; the
/// name and the zone count beside it carry the information, so it is hidden from VoiceOver.
struct LayoutThumbnail: View {
    var layout: GridLayout
    var size: CGSize
    var highlighted = false

    var body: some View {
        Canvas { context, canvasSize in
            var thumb = layout
            thumb.spacing = max(1, Int(canvasSize.width / 28))
            let frames = thumb.frames(in: CGRect(origin: .zero, size: canvasSize))
            for zone in thumb.zones {
                guard let frame = frames[zone.id] else { continue }
                let path = Path(roundedRect: frame, cornerRadius: 2.5)
                context.fill(path, with: .color(LintelBrand.accent.opacity(0.32)))
                context.stroke(path, with: .color(LintelBrand.accent), lineWidth: 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(LintelBrand.card))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(highlighted ? LintelBrand.accent : LintelBrand.hairline, lineWidth: highlighted ? 2 : 1)
        )
        .accessibilityHidden(true)
    }
}
