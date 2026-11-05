import AppKit
import LintelUI
import SwiftUI
import Testing

/// What a pane saw in its environment the last time it rendered.
@MainActor
private final class Seen {
    var textSize: TextSize?
    var dynamicTypeSize: DynamicTypeSize?
    var hostStyle: SettingsHostStyle?
}

/// A pane as plugins write them: sizes only through `lintelTextSize`.
private struct SamplePane: View {
    let seen: Seen
    @Environment(\.lintelTextSize) private var textSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.settingsHostStyle) private var hostStyle

    var body: some View {
        seen.textSize = textSize
        seen.dynamicTypeSize = dynamicTypeSize
        seen.hostStyle = hostStyle
        return Text(verbatim: "Start Indexing").font(textSize.font(.body)).fixedSize()
    }
}

@MainActor
@Suite struct EnvironmentTests {
    private func render(_ view: some View) throws -> NSSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.nsImage).size
    }

    @Test func theDefaultsAreMediumAndTheLegacyWindow() throws {
        let seen = Seen()
        _ = try render(SamplePane(seen: seen))
        #expect(seen.textSize == .medium)
        #expect(seen.hostStyle == .legacyWindow)
    }

    @Test func theModifierSetsTheSizeAndTheDynamicTypeSize() throws {
        for size in TextSize.allCases {
            let seen = Seen()
            _ = try render(SamplePane(seen: seen).lintelTextSize(size))
            #expect(seen.textSize == size)
            #expect(seen.dynamicTypeSize == size.dynamicTypeSize)
        }
    }

    @Test func aPaneRenderedExtraLargeGetsTheScaledFonts() throws {
        let medium = try render(SamplePane(seen: Seen()).lintelTextSize(.medium))
        let extraLarge = try render(SamplePane(seen: Seen()).lintelTextSize(.extraLarge))
        #expect(extraLarge.width > medium.width * 1.2)
        #expect(extraLarge.height > medium.height)
    }

    @Test func theScopeReadsTheSizeWhenItRenders() throws {
        let seen = Seen()
        var size = TextSize.small
        let scope = LintelTextSizeScope(size: { size }, content: { SamplePane(seen: seen) })
        size = .large
        _ = try render(scope)
        #expect(seen.textSize == .large)
        #expect(seen.dynamicTypeSize == TextSize.large.dynamicTypeSize)
    }

    @Test func theMainWindowStyleReachesThePane() throws {
        let seen = Seen()
        _ = try render(SamplePane(seen: seen).environment(\.settingsHostStyle, .mainWindow))
        #expect(seen.hostStyle == .mainWindow)
    }
}
