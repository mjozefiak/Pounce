import Foundation
import LintelKit
import Testing

@testable import LintelApp

extension PluginRegistry {
    /// The plugins users get today: `all` without Notes, which a DEBUG build registers early (spec step 1.2) and
    /// which has its own tests. Step 7.1 removes this filter together with the `#if DEBUG`.
    static var shipped: [any LintelPlugin.Type] { all.filter { $0.manifest.id != "notes" } }
}

/// Notes is registered only in DEBUG builds until step 7.1 of the Notes spec (`2026-11-04-notes-workspace`), so a
/// release build has no Notes plugin, no Keychain item and no `notes.sqlite`.
@Suite struct NotesRegistrationTests {
    private func registrySource() throws -> String {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appending(path: "Sources/LintelApp/PluginRegistry.swift"), encoding: .utf8)
    }

    /// The registry is source-scanned because the tests themselves run in a DEBUG configuration.
    @Test func theRegistryNamesNotesOnlyInsideAnIfDebugBlock() throws {
        let lines = try registrySource().split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let uses = lines.indices.filter { lines[$0].contains("NotesPlugin.self") }
        #expect(uses.count == 1)
        let use = try #require(uses.first)
        let open = try #require(lines[..<use].lastIndex { $0.hasPrefix("#if") })
        #expect(lines[open] == "#if DEBUG")
        let close = try #require(lines[use...].firstIndex { $0.hasPrefix("#endif") })
        // No other conditional between the `#if DEBUG` and the line, and the block closes after it.
        #expect(!lines[open + 1..<use].contains { $0.hasPrefix("#else") || $0.hasPrefix("#elseif") })
        #expect(close > use)
        #expect(!lines[use..<close].contains { $0.hasPrefix("#else") || $0.hasPrefix("#elseif") })
    }

    #if DEBUG
    @Test func aDebugBuildRegistersNotesThatCannotBeDisabled() throws {
        let notes = try #require(PluginRegistry.all.first { $0.manifest.id == "notes" })
        #expect(!notes.manifest.canBeDisabled)
    }
    #else
    @Test func aReleaseBuildHasNoNotesPlugin() {
        #expect(!PluginRegistry.all.contains { $0.manifest.id == "notes" })
    }
    #endif
}
