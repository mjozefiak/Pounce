#if DEBUG
/// DEBUG only: a plugin that can be driven from the QA command route (`--qa-command-file`, `docs/qa.md`) beyond its
/// ordinary commands (verbs that need an argument, such as a file path). Compiled out of release builds, so nothing
/// can reach it there.
@MainActor
public protocol PluginQACommands: LintelPlugin {
    /// Runs one QA line addressed to this plugin and answers a short result (`ok` or why not).
    func runQACommand(_ line: String) async -> String
}
#endif
