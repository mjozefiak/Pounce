import Foundation
import PounceKit
import os

/// Clipboard history (spec Phase 2): an encrypted history of what the user copies, opened with
/// Command-Shift-V, that pastes the chosen entry into the previous app.
@MainActor
public final class ClipboardPlugin: PouncePlugin {
    public nonisolated static let manifest = PluginManifest(
        id: "clipboard",
        displayName: LocalizedStringResource("Clipboard History", comment: "Plugin name of the clipboard history"),
        symbolName: "doc.on.clipboard",
        order: 30
    )

    private let context: PluginContext
    private(set) var store: ClipStore?

    public init(context: PluginContext) {
        self.context = context
    }

    public func activate() async throws {
        let opener = HistoryOpener(directory: context.storageDirectory, keyStore: KeyStore(keychain: context.keychain))
        opener.purgeOldArchives(now: Date())
        if case .opened(let store, _) = try opener.open(now: Date()) {
            self.store = store
        }
    }

    public func deactivate() async {
        try? store?.close()
        store = nil
    }
}
