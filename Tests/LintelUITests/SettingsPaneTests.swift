import AppKit
import SwiftUI
import Testing

@testable import LintelUI

@MainActor
@Suite struct SettingsPaneTests {
    private func size(_ view: some View) throws -> NSSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.nsImage).size
    }

    @Test func aPaneRendersWithAndWithoutAdvancedAndData() throws {
        let basicsOnly = SettingsPane { Text(verbatim: "Basics") }
        let full = SettingsPane {
            Text(verbatim: "Basics")
        } advanced: {
            Text(verbatim: "Advanced")
        } data: {
            Text(verbatim: "Data")
        }
        #expect(try size(basicsOnly.frame(width: 400, height: 300)).width > 0)
        #expect(try size(full.frame(width: 400, height: 300)).width > 0)
    }

    @Test func aFooterAndAConfirmSheetRender() throws {
        let footer = SettingsFooter("Stays on this Mac.").lintelTextSize(.extraLarge)
        #expect(try size(footer).height > 0)
        let sheet = ConfirmSheet(
            prompt: "Erase all history?", detail: "This can’t be undone.", confirmTitle: "Erase",
            onConfirm: {}, onCancel: {})
        #expect(try size(sheet).width >= 380)
    }

    /// Step 6.5a: in the main window Advanced is a plain line (no card) and the headers are the small secondary
    /// style; the old window keeps the `DisclosureGroup`. Both render, expanded or not.
    @Test func theMainWindowDisclosureRendersCollapsedAndExpanded() throws {
        for expanded in [false, true] {
            let section = Form {
                SettingsDisclosureSection(isExpanded: .constant(expanded)) {
                    Text(verbatim: "Row")
                } label: {
                    Text(verbatim: "Advanced")
                }
                Section {
                    Text(verbatim: "Data row")
                } header: {
                    Text(verbatim: "Data").settingsSectionHeader()
                }
            }
            .formStyle(.grouped)
            .frame(width: 400, height: 300)
            #expect(try size(section.environment(\.settingsHostStyle, .mainWindow)).width > 0)
            #expect(try size(section).width > 0)
        }
    }

    @Test func footerLimitMatchesTheScanningRule() {
        #expect(SettingsFooter.maxLength == 140)
    }
}

/// `ConfirmSheet` and `destructiveConfirmation` (spec `2026-11-04-lintel-main-window`, step 3.4).
@MainActor
@Suite struct ConfirmSheetTests {
    private final class Deleter { var deletions = 0 }

    private func sheet(_ deleter: Deleter, cancelled: @escaping () -> Void = {}) -> ConfirmSheet {
        ConfirmSheet(
            prompt: "Erase?", detail: "This can’t be undone.", confirmTitle: "Erase",
            onConfirm: { deleter.deletions += 1 }, onCancel: cancelled)
    }

    @Test func cancellingDeletesNothingAndConfirmingDeletesOnce() {
        let deleter = Deleter()
        var cancels = 0
        let view = sheet(deleter) { cancels += 1 }
        view.cancelTapped()
        view.cancelTapped()
        #expect(deleter.deletions == 0)
        #expect(cancels == 2)
        view.confirmTapped()
        #expect(deleter.deletions == 1)
    }

    @Test func cancelIsTheOnlyDefaultButton() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/LintelUI/Components/ConfirmSheet.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let sheet = try #require(source.components(separatedBy: "public struct DestructiveConfirmation").first)
        #expect(sheet.components(separatedBy: ".keyboardShortcut(.defaultAction)").count == 2)
        // The default action sits on the Cancel button, never on the destructive one.
        let destructive = try #require(sheet.range(of: "Button(role: .destructive, action: confirmTapped)"))
        let cancel = try #require(
            sheet.range(of: "Button(action: cancelTapped) {\n                    Text(\"Cancel\""))
        let defaultAction = try #require(sheet.range(of: ".keyboardShortcut(.defaultAction)"))
        // Cancel on the left, the filled red confirm button on the right.
        #expect(cancel.lowerBound < destructive.lowerBound)
        #expect(cancel.upperBound <= defaultAction.lowerBound)
        #expect(defaultAction.upperBound <= destructive.lowerBound)
        let after = sheet[destructive.upperBound...]
        #expect(!after.contains(".keyboardShortcut(.defaultAction)"))
    }

    @Test func confirmingRunsTheActionBeforeTheSheetCloses() {
        // Like Meetings' retention binding: closing the sheet clears the pending action.
        final class Pending {
            var days: Int? = 30
            var applied: [Int] = []
        }
        let pending = Pending()
        let binding = Binding<Bool>(
            get: { pending.days != nil }, set: { if !$0 { pending.days = nil } })
        confirmThenClose(isPresented: binding) {
            if let days = pending.days { pending.applied.append(days) }
        }()
        #expect(pending.applied == [30])
        #expect(binding.wrappedValue == false)
    }

    @Test func theCopyKeepsItsWords() {
        let confirmation = DestructiveConfirmation(prompt: "Erase?", detail: "Gone.", confirmTitle: "Erase")
        #expect(confirmation.legacyTitleVisible == false)
        #expect(String(localized: confirmation.confirmTitle) == "Erase")
    }
}
