import AppKit
import SwiftUI
import Testing

@testable import WindowsPlugin

/// QA round 4, D7: the Layouts header's "Rename…" was clipped to "Rena…" at the narrowest window. The action row wraps
/// instead of clipping.
@Suite struct WrapLayoutTests {
    @Test func linesKeepEveryItemOnceInOrderAndNeverExceedTheWidthUnlessAnItemAloneIsWider() {
        let widths: [CGFloat] = [60, 90, 110, 60, 80]
        for maxWidth in stride(from: 40, through: 600, by: 20) {
            let lines = WrapMath.lines(widths: widths, maxWidth: CGFloat(maxWidth), spacing: 8)
            #expect(lines.flatMap { $0 } == Array(widths.indices), "width \(maxWidth)")
            for line in lines where line.count > 1 {
                let used = line.map { widths[$0] }.reduce(0, +) + 8 * CGFloat(line.count - 1)
                #expect(used <= CGFloat(maxWidth), "width \(maxWidth), line \(line)")
            }
        }
        #expect(WrapMath.lines(widths: [], maxWidth: 100, spacing: 8).isEmpty)
    }

    /// The narrowest detail column (window 900, sidebar 280, paddings and thumbnail) is about 394 pt: five controls of
    /// the longest Polish labels do not fit one line, and two lines hold them.
    @Test func theActionRowOfTheNarrowestWindowWrapsToTwoLines() {
        let lines = WrapMath.lines(widths: [64, 104, 118, 66, 92], maxWidth: 394, spacing: 8)
        #expect(lines.count == 2)
    }

    /// The real layout: five fixed-size controls in a 250 pt column take three lines and none is placed outside it.
    @MainActor @Test func theLayoutWrapsRealViewsAndKeepsEveryControlItsFullSize() {
        let view = WrapLayout(spacing: 8, lineSpacing: 6) {
            ForEach(0..<5, id: \.self) { _ in Color.red.frame(width: 100, height: 20) }
        }
        .frame(width: 250)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        #expect(size.width <= 250 + 0.5)
        // Two controls fit a line (100 + 8 + 100): 3 lines of 20 and two gaps of 6.
        #expect(abs(size.height - (3 * 20 + 2 * 6)) < 0.5, "height \(size.height)")
    }
}
