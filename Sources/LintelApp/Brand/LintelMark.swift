import AppKit
import SwiftUI

/// The ring of the Lintel mark on its 256-point grid: an outer radius of 112, an inner radius of 66 and a 60°
/// cut centred on the upper left (-135°), so the edges of the cut sit on multiples of 15°. The small cut
/// (menu bar, 24 pt and below) has a thinner ring so the core stays readable.
nonisolated struct LintelMarkRing: Shape {
    var small = false

    static let outerRadius: CGFloat = 112
    static let innerRadius: CGFloat = 66
    static let smallOuterRadius: CGFloat = 116
    static let smallInnerRadius: CGFloat = 60
    static let cutCenter: Double = -135
    static let cutWidth: Double = 60

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 256
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = (small ? Self.smallOuterRadius : Self.outerRadius) * unit
        let inner = (small ? Self.smallInnerRadius : Self.innerRadius) * unit
        let start = Self.cutCenter + Self.cutWidth / 2
        let end = Self.cutCenter - Self.cutWidth / 2 + 360
        func point(_ radius: CGFloat, _ degrees: Double) -> CGPoint {
            CGPoint(
                x: center.x + radius * CGFloat(cos(degrees * .pi / 180)),
                y: center.y + radius * CGFloat(sin(degrees * .pi / 180)))
        }
        var path = Path()
        path.move(to: point(outer, start))
        // SwiftUI measures `clockwise` as if y pointed up, so the on-screen clockwise sweep is `false`.
        path.addArc(
            center: center, radius: outer, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        path.addLine(to: point(inner, end))
        path.addArc(
            center: center, radius: inner, startAngle: .degrees(end), endAngle: .degrees(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// The Lintel mark: a ring with a cut and a core in the accent colour.
struct LintelMark: View {
    var ring: Color = .primary
    var core: Color = LintelBrand.accent
    var small = false

    var body: some View {
        GeometryReader { proxy in
            let unit = min(proxy.size.width, proxy.size.height) / 256
            ZStack {
                LintelMarkRing(small: small).fill(ring)
                Circle()
                    .fill(core)
                    .frame(width: (small ? 80 : 68) * unit, height: (small ? 80 : 68) * unit)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

extension LintelMark {
    /// The menu bar glyph: a template image, so the system draws it in the menu bar's colour. The core is
    /// part of the same black shape, separated from the ring by the gap.
    @MainActor
    static func menuBarImage(points: CGFloat = 18) -> NSImage {
        let content = ZStack {
            LintelMarkRing(small: true).fill(.black)
            Circle().fill(.black).frame(width: points * 80 / 256, height: points * 80 / 256)
        }
        .frame(width: points, height: points)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: points, height: points))
        image.size = NSSize(width: points, height: points)
        image.isTemplate = true
        return image
    }
}
