import Foundation

/// A CLI version as numbers. Only the first three components are read.
public struct ProviderVersion: Comparable, Sendable, Equatable {
    public let parts: [Int]

    public init(_ parts: [Int]) { self.parts = parts }

    /// Reads the first `1.2.3` in a `--version` line such as `2.1.328 (Claude Code)`. Nil when there is none.
    public init?(parsing text: String) {
        let separators = CharacterSet(charactersIn: "0123456789.").inverted
        for token in text.components(separatedBy: separators) where token.contains(".") {
            let numbers = token.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            if numbers.count >= 2, numbers.allSatisfy({ $0 != nil }) {
                self.parts = numbers.compactMap { $0 }
                return
            }
        }
        return nil
    }

    public static func < (lhs: ProviderVersion, rhs: ProviderVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// What the CLI printed, reduced to what the runner needs.
public enum ProviderParsedOutput: Sendable, Equatable {
    case answer(String)
    /// The answer was cut by the output limit. The text is lost (the CLI replaces it with an error line).
    case truncated
    case failure(ProviderFailure)
}

public struct ProviderModel: Sendable, Equatable {
    public let id: String
    public let displayName: String
    /// The estimated tokens of transcript one request takes (spec `2026-11-10-external-ai-providers`, Q12). A working
    /// number until the measurement of step 0.2; a model id the user typed gets `ProviderDescriptor.defaultInputBudgetTokens`.
    public let inputBudgetTokens: Int
    /// A model that uses more of the user's subscription limit and takes longer than the default one: Settings shows
    /// a note under the model menu while it is chosen (owner decision D8/D15, 2026-11-20).
    public let heavier: Bool

    public init(
        id: String, displayName: String, inputBudgetTokens: Int = ProviderDescriptor.defaultInputBudgetTokens,
        heavier: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.inputBudgetTokens = inputBudgetTokens
        self.heavier = heavier
    }
}

/// Data and pure functions of one provider (spec: `ProviderDescriptor`). The argv is made in `arguments`, nowhere
/// else, and checked by `isolationProblems` before every process with content.
public struct ProviderDescriptor: Sendable {
    public let id: ProviderID
    /// The company the text goes to; the consent window names it.
    public let recipient: String
    public let displayName: String
    public let binaryNames: [String]
    public let versionArguments: [String]
    public let authStatusArguments: [String]
    public let supportedVersions: ClosedRange<ProviderVersion>
    public let models: [ProviderModel]
    /// Set to `true` in code only after the isolation canary (ADR 0011). While `false`, the runner starts nothing.
    public let isolationVerified: Bool
    /// The only variables a child gets, apart from the fixed `PATH`.
    public let environmentAllowlist: [String]
    /// Makes the argv from a model id and our static prompt. Injectable so a test can hand the runner a descriptor
    /// whose argv breaks an isolation requirement.
    let argumentBuilder: @Sendable (String, String) throws -> [String]

    init(
        id: ProviderID, recipient: String, displayName: String, binaryNames: [String], versionArguments: [String],
        authStatusArguments: [String], supportedVersions: ClosedRange<ProviderVersion>, models: [ProviderModel],
        isolationVerified: Bool, environmentAllowlist: [String],
        argumentBuilder: @escaping @Sendable (String, String) throws -> [String] = ProviderDescriptor.claudeArguments
    ) {
        self.id = id
        self.recipient = recipient
        self.displayName = displayName
        self.binaryNames = binaryNames
        self.versionArguments = versionArguments
        self.authStatusArguments = authStatusArguments
        self.supportedVersions = supportedVersions
        self.models = models
        self.isolationVerified = isolationVerified
        self.environmentAllowlist = environmentAllowlist
        self.argumentBuilder = argumentBuilder
    }

    func with(isolationVerified: Bool) -> ProviderDescriptor {
        ProviderDescriptor(
            id: id, recipient: recipient, displayName: displayName, binaryNames: binaryNames,
            versionArguments: versionArguments, authStatusArguments: authStatusArguments,
            supportedVersions: supportedVersions, models: models, isolationVerified: isolationVerified,
            environmentAllowlist: environmentAllowlist, argumentBuilder: argumentBuilder)
    }

    /// The model a consumer offers first: the first entry of `models`.
    public var defaultModelID: String { models.first?.id ?? "" }

    /// The input budget of a model the catalog does not list.
    public static let defaultInputBudgetTokens = 100_000

    /// The budget of `model`: its catalog entry, else the default.
    public func inputBudgetTokens(forModel model: String) -> Int {
        models.first { $0.id == model }?.inputBudgetTokens ?? Self.defaultInputBudgetTokens
    }

    // MARK: Claude Code

    /// Claude Code CLI. `isolationVerified` stays `false` until canary point 5 (TCC) has an owner decision (ADR 0011).
    public static let claudeCode = ProviderDescriptor(
        id: .claudeCode,
        recipient: "Anthropic",
        displayName: "Claude Code",
        binaryNames: ["claude"],
        versionArguments: ["--version"],
        authStatusArguments: ["auth", "status"],
        // Measured with 2.1.328; the canary is repeated for every new range.
        supportedVersions: ProviderVersion([2, 1, 0])...ProviderVersion([2, 1, Int.max]),
        // The models Settings offers (owner decision D15, 2026-11-20); `sonnet` is the default (`defaultModelID`). Quality
        // gate G was measured on `sonnet` ONLY: `opus` and `fable` passed only the short canary (alias, JSON shape,
        // time, budget) and their input budgets are an ASSUMPTION (not above sonnet's). HAIKU IS HIDDEN until its own
        // gate G has a result: to offer it, add `ProviderModel(id: "haiku", displayName: "Haiku")` to this list and
        // nothing else (the menu, the argv check and the marker all read `models`). There is no per-model minimum CLI
        // version: a CLI that does not know an alias fails the run (never a silent switch to another model).
        models: [
            ProviderModel(id: "sonnet", displayName: "Sonnet"),
            ProviderModel(id: "opus", displayName: "Opus", heavier: true),
            ProviderModel(id: "fable", displayName: "Fable", heavier: true),
        ],
        isolationVerified: false,
        environmentAllowlist: Self.claudeEnvironmentAllowlist)

    /// `USER` is needed: without it the CLI does not find the login in the Keychain. Authentication variables pass
    /// unchanged (the terms forbid disabling the user's methods); every other `CLAUDE_*` / `ANTHROPIC_*` does not.
    static let claudeEnvironmentAllowlist: [String] = [
        "HOME", "USER", "LANG", "TMPDIR", "CLAUDE_CONFIG_DIR",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "no_proxy", "all_proxy",
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
    ]

    // MARK: argv

    /// Flags that must be present, with the value they need (`nil`: no value of its own).
    static let requiredFlags: [(name: String, emptyValue: Bool)] = [
        ("--setting-sources", true), ("--strict-mcp-config", false), ("--no-session-persistence", false),
        ("--tools", true), ("--disable-slash-commands", false), ("--safe-mode", false),
    ]

    static let forbiddenFlags: [String] = [
        "--settings", "--mcp-config", "--plugin-dir", "--plugin-url", "--add-dir", "--agents", "--continue",
        "--resume", "-c", "-r", "--append-system-prompt", "--dangerously-skip-permissions",
    ]

    /// Options whose next argument is a value that is not examined (a model id, our static prompt).
    private static let opaqueValueFlags: Set<String> = ["--model", "--system-prompt", "--output-format"]

    private static let maxSystemPromptBytes = 16 * 1024

    /// A model id is a short token of letters, digits and `. _ - [ ]`: no whitespace, quote, `$`, `;` or leading `-`.
    public static func isValidModelID(_ model: String) -> Bool {
        guard let first = model.unicodeScalars.first, model.utf8.count <= 64,
            first.isASCII, CharacterSet.alphanumerics.contains(first)
        else { return false }
        return model.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-_[]".unicodeScalars.contains($0))
        }
    }

    /// The one place the argv of a content process is made. Content never goes in it, only the model id and our static prompt.
    func arguments(model: String, systemPrompt: String) throws -> [String] {
        guard Self.isValidModelID(model) else { throw ProviderError.invalidModel }
        // A prompt that starts with `-` would be read as a flag by a CLI parser that is not greedy for values; ours
        // is a static text, so it is refused rather than relying on the parser.
        guard systemPrompt.utf8.count <= Self.maxSystemPromptBytes, !systemPrompt.contains("\0"),
            !systemPrompt.hasPrefix("-")
        else {
            throw ProviderError.invalidRequest
        }
        return try argumentBuilder(model, systemPrompt)
    }

    /// The order is the golden list of ADR 0011 ("Flags (golden list for the descriptor)").
    static func claudeArguments(model: String, systemPrompt: String) throws -> [String] {
        var argv = [
            "-p",
            "--model", model,
            "--output-format", "json",
            "--tools", "",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--safe-mode",
        ]
        if !systemPrompt.isEmpty { argv += ["--system-prompt", systemPrompt] }
        return argv
    }

    /// Pure check of an argv: the names of the missing isolation requirements and of the forbidden flags found.
    /// An empty result is the only one the runner accepts. Names are constants, never argument text.
    func isolationProblems(arguments: [String]) -> [String] {
        var problems: [String] = []
        var seen: [String: [String]] = [:]  // flag -> values met (empty string for a flag without value)
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let name =
                argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? argument
            let inline = argument.contains("=") ? String(argument.drop(while: { $0 != "=" }).dropFirst()) : nil
            if Self.forbiddenFlags.contains(name) {
                problems.append("forbidden:\(name)")
            } else if let required = Self.requiredFlags.first(where: { $0.name == name }) {
                if let inline {
                    seen[name, default: []].append(inline)
                } else if required.emptyValue {
                    let value = index + 1 < arguments.count ? arguments[index + 1] : "<missing>"
                    seen[name, default: []].append(value)
                    index += 1
                } else {
                    seen[name, default: []].append("")
                }
            } else if Self.opaqueValueFlags.contains(name), inline == nil {
                index += 1
            }
            index += 1
        }
        for required in Self.requiredFlags {
            guard let values = seen[required.name] else {
                problems.append("missing:\(required.name)")
                continue
            }
            if required.emptyValue, values.contains(where: { !$0.isEmpty }) {
                problems.append("value:\(required.name)")
            }
        }
        return problems
    }

    // MARK: output

    /// Reads the `--output-format json` result. The CLI reports its errors here, with exit code 1 and an empty stderr.
    func parseOutput(_ stdout: Data) -> ProviderParsedOutput {
        guard let object = Self.resultObject(stdout) else { return .failure(.other) }
        let text = (object["result"] as? String) ?? ""
        if (object["is_error"] as? Bool) == true {
            if Self.isTruncationLine(text) { return .truncated }
            return .failure(Self.classifyText(text))
        }
        return text.isEmpty ? .failure(.other) : .answer(text)
    }

    /// Sorts a failed run into the closed set. `stdout` is read for the JSON error, `stderr` for an unknown flag.
    /// Neither is kept.
    func classify(stdout: Data, stderr: Data, exitCode: Int32) -> ProviderFailure {
        let err = String(decoding: stderr, as: UTF8.self).lowercased()
        if err.contains("unknown option") || err.contains("unknown argument") || err.contains("error: option") {
            return .incompatibleVersion
        }
        if let object = Self.resultObject(stdout), (object["is_error"] as? Bool) == true {
            let text = (object["result"] as? String) ?? ""
            return Self.classifyText(text)
        }
        return Self.classifyText(err)
    }

    /// The exact model that answered: the one key of `modelUsage` in the CLI's JSON result (`claude-sonnet-5-5` for
    /// the alias `sonnet`). `nil` when the result names none or several, or the name is not a valid model id.
    func exactModel(stdout: Data) -> String? {
        guard let object = Self.resultObject(stdout), let usage = object["modelUsage"] as? [String: Any],
            usage.count == 1, let id = usage.keys.first, Self.isValidModelID(id)
        else { return nil }
        return id
    }

    private static func resultObject(_ stdout: Data) -> [String: Any]? {
        guard let value = try? JSONSerialization.jsonObject(with: stdout) else { return nil }
        if let object = value as? [String: Any] { return object }
        if let events = value as? [[String: Any]] {  // some versions return the event array
            return events.last { ($0["type"] as? String) == "result" }
        }
        return nil
    }

    private static func isTruncationLine(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("api error:") && lower.contains("exceeded") && lower.contains("output token maximum")
    }

    private static func classifyText(_ text: String) -> ProviderFailure {
        let s = text.lowercased()
        if ["not logged in", "please run /login", "log in", "login", "authentication", "oauth", "api key"]
            .contains(where: s.contains)
        {
            return .notSignedIn
        }
        if ["unknown option", "unknown argument", "invalid value", "error: option"].contains(where: s.contains) {
            return .incompatibleVersion
        }
        if s.contains("not available"), s.contains("plan") || s.contains("model") { return .modelNotAvailable }
        if ["rate limit", "usage limit", "overloaded", "429"].contains(where: s.contains) { return .rateLimited }
        if ["enotfound", "econnrefused", "network", "timed out", "unable to connect", "fetch failed"]
            .contains(where: s.contains)
        {
            return .network
        }
        return .other
    }

    /// `ready` / `incompatibleVersion` / `notSignedIn` from the two probe outputs (never kept, never logged).
    func status(versionOutput: Data, authOutput: Data?) -> ProviderStatus {
        guard let version = ProviderVersion(parsing: String(decoding: versionOutput, as: UTF8.self)) else {
            return .incompatibleVersion
        }
        if version > supportedVersions.upperBound { return .newerVersion }
        guard supportedVersions.contains(version) else { return .incompatibleVersion }
        guard let authOutput, let object = try? JSONSerialization.jsonObject(with: authOutput) as? [String: Any],
            (object["loggedIn"] as? Bool) == true
        else { return .notSignedIn }
        return .ready
    }
}
