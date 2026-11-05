import AppKit
import SwiftUI
import Testing

@testable import LintelUI

/// Spec `2026-11-04-lintel-main-window`, step 5.3 (owner decision L1-39): a `DestructiveConfirmation` may carry
/// a checkbox, off by default, whose state reaches the confirm closure; only the main window's sheet shows it.
@MainActor
@Suite struct KeptCopiesOptionTests {
    private final class Deleter { var confirmed: [Bool] = [] }

    private func sheet(
        _ deleter: Deleter, option: DestructiveConfirmation.Option?, cancelled: @escaping () -> Void = {}
    ) -> ConfirmSheet {
        ConfirmSheet(
            prompt: "Erase?", detail: "It cannot be undone.", confirmTitle: "Erase", option: option,
            onConfirm: { deleter.confirmed.append($0) }, onCancel: cancelled)
    }

    @Test func theKeptCopiesCheckboxIsOffByDefaultAndSaysWhatStays() {
        let option = DestructiveConfirmation.Option.keptNotesCopies
        #expect(option.isOnByDefault == false)
        #expect(option.title.key == "Also delete kept copies")
        #expect(
            option.explanation?.key == "Copies you edited or commented on in Notes stay until you delete them there.")
        #expect(sheet(Deleter(), option: option).initialOptionState == false)
    }

    @Test func confirmingPassesTheCheckboxStateToTheClosure() {
        let deleter = Deleter()
        sheet(deleter, option: .keptNotesCopies).confirmTapped()
        sheet(deleter, option: .init(title: "Also", isOnByDefault: true)).confirmTapped()
        sheet(deleter, option: nil).confirmTapped()
        #expect(deleter.confirmed == [false, true, false])
    }

    @Test func cancellingASheetWithTheCheckboxDeletesNothing() {
        let deleter = Deleter()
        var cancels = 0
        sheet(deleter, option: .keptNotesCopies) { cancels += 1 }.cancelTapped()
        #expect(deleter.confirmed.isEmpty)
        #expect(cancels == 1)
    }

    @Test func theFlagReachesTheActionBeforeTheSheetCloses() {
        var isPresented = true
        var received: [Bool] = []
        let binding = Binding<Bool>(get: { isPresented }, set: { isPresented = $0 })
        let confirm: (Bool) -> Void = { received.append($0) }
        confirmThenClose(isPresented: binding, confirm)(true)
        #expect(received == [true])
        #expect(isPresented == false)
    }

    @Test func onlyTheMainWindowShowsTheCheckbox() {
        let plain = DestructiveConfirmation(prompt: "Erase?", detail: "Gone.", confirmTitle: "Erase")
        #expect(plain.option == nil)
        let withOption = plain.with(option: .keptNotesCopies)
        #expect(withOption.option(in: .mainWindow) != nil)
        #expect(withOption.option(in: .legacyWindow) == nil)
        #expect(plain.option(in: .mainWindow) == nil)
        // The words stay the same.
        #expect(withOption.prompt.key == plain.prompt.key)
        #expect(withOption.confirmTitle.key == plain.confirmTitle.key)
        #expect(withOption.legacyTitleVisible == plain.legacyTitleVisible)
    }

    @Test func aSheetWithTheCheckboxRenders() throws {
        let view = sheet(Deleter(), option: .keptNotesCopies).lintelTextSize(.extraLarge)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        #expect(try #require(renderer.nsImage).size.width >= 380)
    }
}
