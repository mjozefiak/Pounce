import FluidAudio
import Foundation
import PounceKit
import SwiftUI
import os

/// Voice dictation (spec: Dyktowanie głosowe): records under a global shortcut, transcribes with a speech
/// model that runs inside Pounce, and pastes the text into the app in front. Audio never leaves the Mac
/// and is never written to disk.
///
/// Settings: `plugins.dictation.*` (see `DictationSettings.Key`). Disabled by default: the feature needs a
/// model download and the microphone.
@MainActor
public final class DictationPlugin: PouncePlugin {
    public nonisolated static let manifest = PluginManifest(
        id: "dictation",
        displayName: LocalizedStringResource("Dictation", comment: "Plugin name of voice dictation"),
        symbolName: "mic",
        order: 40,
        defaultEnabled: false
    )

    static let recordCommandID = "dictation.record"
    /// The Core ML build of Parakeet that dictation loads (ADR 0003); resolved here so the dependency links.
    static let parakeetVersion = AsrModelVersion.ultra

    let context: PluginContext

    public init(context: PluginContext) {
        self.context = context
    }

    public var commands: [PluginCommand] {
        [
            PluginCommand(
                id: Self.recordCommandID,
                title: LocalizedStringResource("Dictate", comment: "Menu item and command that starts dictation"),
                symbolName: "mic",
                defaultShortcut: KeyShortcut(key: "d", modifiers: [.control, .option]),
                onKeyEvent: { _ in }
            )
        ]
    }

    public var requiredPermissions: Set<Permission> { [.microphone, .accessibility] }
}
