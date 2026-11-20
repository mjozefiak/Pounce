import Foundation
import LintelProviders

/// "Sent to": what the library row and the note's Details say about the provider that wrote the notes (owner
/// decision D9=A). The database keeps the exact model the CLI reported (`claude-opus-5-5`), or the alias when the
/// result named none. The row shows the short name ("Claude · Opus"), Details the exact identifier. A note
/// without a mark claims nothing: a failed run may still have sent the transcript.
enum ProviderMark {
    /// The company-facing short name of a provider ("Claude" for the Claude Code CLI).
    static func shortName(of provider: String) -> String? {
        MeetingsSettings.knownProviders.first { $0.id.rawValue == provider }.map {
            $0.recipient == "Anthropic" ? "Claude" : $0.displayName
        }
    }

    /// "Sent to: Claude · Opus".
    static func chip(provider: String?, model: String?) -> String? {
        guard let provider, !provider.isEmpty, let name = shortName(of: provider) else { return nil }
        let family = model.flatMap { shortModel($0, provider: provider) }
        let value = family.map { "\(name) · \($0)" } ?? name
        return String(
            localized: "Sent to: \(value)", comment: "Meeting library badge: the provider that wrote the notes")
    }

    /// "Claude · claude-opus-5-5".
    static func detail(provider: String?, model: String?) -> String? {
        guard let provider, !provider.isEmpty, let name = shortName(of: provider) else { return nil }
        guard let model, !model.isEmpty else { return name }
        return "\(name) · \(model)"
    }

    /// The display name of the model family: the catalog entry whose alias the exact id contains
    /// (`claude-opus-5-5` → "Opus"), the id itself otherwise.
    static func shortModel(_ model: String, provider: String) -> String? {
        let descriptor = MeetingsSettings.knownProviders.first { $0.id.rawValue == provider }
        if let entry = descriptor?.models.first(where: { $0.id == model }) { return entry.displayName }
        if let entry = descriptor?.models.first(where: { model.contains($0.id) }) { return entry.displayName }
        if model == "haiku" || model.contains("haiku") { return "Haiku" }
        return model
    }
}
