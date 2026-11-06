import AppKit
import SwiftUI
import Testing

@testable import LintelUI

/// Step 6.6f: the welcome screen's shared single column (prototype `shell-welcome-*`).
@MainActor
@Suite struct WelcomeStepTests {
    private func size(_ view: some View) throws -> NSSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.nsImage).size
    }

    @Test func theLayoutHasThePrototypeMeasurements() {
        #expect(WelcomeLayout.width == 600)
        #expect(WelcomeLayout.minHeight == 388)
        #expect(WelcomeLayout.contentInset == 40)
        #expect(WelcomeLayout.markSize == 44)
        #expect(WelcomeLayout.controlsSpacing == 12)
    }

    @Test func aPageRendersAtTheColumnWidthAndAtLeastTheWindowHeight() throws {
        let page = WelcomeStepLayout(heading: "Dictation", text: "One line.", accessibilityLabel: "Step 3 of 5") {
            Circle()
        } content: {
            WelcomeStepColumn {
                WelcomeStepItem(Text(verbatim: "Allow the microphone.")) {
                    Button(action: {}, label: { Text(verbatim: "Allow Microphone") })
                }
                WelcomeStepItem(Text(verbatim: "Get the model."), isDone: true) { EmptyView() }
                WelcomeStepItem(Text(verbatim: "Never recorded."))
                WelcomeStepNote(Text(verbatim: "A note."))
            }
        } footer: {
            Text(verbatim: "Skip")
        }
        let rendered = try size(page)
        #expect(rendered.width == WelcomeLayout.width)
        #expect(rendered.height >= WelcomeLayout.minHeight)
    }

    @Test func aPageWithoutTextOrControlsKeepsTheWindowHeight() throws {
        let page = WelcomeStepLayout(heading: "You’re set", text: nil, accessibilityLabel: "") {
            Circle()
        } content: {
            EmptyView()
        } footer: {
            EmptyView()
        }
        #expect(try size(page).height >= WelcomeLayout.minHeight)
    }

    @Test func aDonePartRendersWithAndWithoutItsOwnText() throws {
        #expect(try size(WelcomeStepDone()).width > 0)
        #expect(try size(WelcomeStepDone(Text(verbatim: "Accessibility is allowed."))).width > 0)
    }
}
