import AppKit
import LintelUI
import SwiftUI
import Testing

/// What a pane saw in its environment the last time it rendered.
@MainActor
private final class Seen {
    var textSize: TextSize?
    var dynamicTypeSize: DynamicTypeSize?
}

/// A pane as plugins write them: sizes only through `lintelTextSize`.
private struct SamplePane: View {
    let seen: Seen
    @Environment(\.lintelTextSize) private var textSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        seen.textSize = textSize
        seen.dynamicTypeSize = dynamicTypeSize
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

    @Test func theDefaultIsMedium() throws {
        let seen = Seen()
        _ = try render(SamplePane(seen: seen))
        #expect(seen.textSize == .medium)
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

    @Test func aModelChoiceRowRenderedExtraLargeScalesItsLink() throws {
        let row = ModelChoiceRow(title: "Parakeet", state: .notInstalled, open: {})
        let medium = try render(row.lintelTextSize(.medium))
        let extraLarge = try render(row.lintelTextSize(.extraLarge))
        #expect(extraLarge.width > medium.width * 1.15)
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
}
