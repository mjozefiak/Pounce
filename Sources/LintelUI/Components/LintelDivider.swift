import SwiftUI

/// The prototype's 1 pt hairline (`--hair`) in place of the system `Divider`: the sidebar's edge, the welcome
/// screen's footer border.
public struct LintelDivider: View {
    private let axis: Axis

    public init(axis: Axis = .horizontal) {
        self.axis = axis
    }

    public var body: some View {
        Rectangle()
            .fill(LintelBrand.hairline)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .accessibilityHidden(true)
    }
}
