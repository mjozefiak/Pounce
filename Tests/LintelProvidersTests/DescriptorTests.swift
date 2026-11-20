import Foundation
import Testing

@testable import LintelProviders

@Suite struct DescriptorTests {
    let descriptor = ProviderDescriptor.claudeCode

    @Test func goldenArgv() throws {
        let argv = try descriptor.arguments(model: "sonnet", systemPrompt: "Static prompt.")
        #expect(
            argv == [
                "-p", "--output-format", "json", "--tools", "", "--no-session-persistence",
                "--disable-slash-commands", "--strict-mcp-config", "--setting-sources", "", "--model", "sonnet",
                "--system-prompt", "Static prompt.",
            ])
        #expect(descriptor.isolationProblems(arguments: argv).isEmpty)
    }

    @Test func productArgvHasNoUserDataOrPath() throws {
        let argv = try descriptor.arguments(model: "haiku", systemPrompt: "")
        #expect(!argv.contains("--system-prompt"))
        #expect(!argv.joined(separator: " ").contains("/"))
    }

    @Test func descriptorIsNotVerifiedUntilTheCanaryDecision() {
        #expect(!ProviderDescriptor.claudeCode.isolationVerified)
    }

    @Test(arguments: [
        "a b", "x;rm", "$(id)", "--tools", "", "sonnet\n", "mo\"del", "über", "-x", String(repeating: "a", count: 65),
    ])
    func modelIDsWithMetacharactersAreRejected(model: String) {
        #expect(!ProviderDescriptor.isValidModelID(model))
        #expect(throws: ProviderError.invalidModel) { try descriptor.arguments(model: model, systemPrompt: "") }
    }

    @Test(arguments: ["sonnet", "haiku", "claude-sonnet-5-5", "claude-opus-5-5[1m]", "m.1_x"])
    func ordinaryModelIDsPass(model: String) {
        #expect(ProviderDescriptor.isValidModelID(model))
    }

    @Test(arguments: [
        "--setting-sources", "--strict-mcp-config", "--no-session-persistence", "--tools", "--disable-slash-commands",
    ])
    func removingAnyRequirementNamesIt(flag: String) throws {
        var argv = try descriptor.arguments(model: "sonnet", systemPrompt: "")
        let index = try #require(argv.firstIndex(of: flag))
        let takesValue = flag == "--setting-sources" || flag == "--tools"
        argv.removeSubrange(index...(takesValue ? index + 1 : index))
        #expect(descriptor.isolationProblems(arguments: argv) == ["missing:\(flag)"])
    }

    @Test(arguments: ["user", "project", "local", "user,project"])
    func nonEmptySettingSourcesIsAProblem(value: String) throws {
        var argv = try descriptor.arguments(model: "sonnet", systemPrompt: "")
        argv[argv.firstIndex(of: "--setting-sources")! + 1] = value
        #expect(descriptor.isolationProblems(arguments: argv) == ["value:--setting-sources"])
        #expect(
            descriptor.isolationProblems(arguments: argv + ["--setting-sources=\(value)"]) == [
                "value:--setting-sources"
            ])
    }

    @Test func nonEmptyToolsIsAProblem() throws {
        var argv = try descriptor.arguments(model: "sonnet", systemPrompt: "")
        argv[argv.firstIndex(of: "--tools")! + 1] = "Bash"
        #expect(descriptor.isolationProblems(arguments: argv) == ["value:--tools"])
    }

    @Test(arguments: [
        "--settings", "--mcp-config", "--plugin-dir", "--plugin-url", "--add-dir", "--agents", "--continue",
        "--resume", "-c", "-r", "--append-system-prompt", "--dangerously-skip-permissions",
    ])
    func everyForbiddenFlagIsFound(flag: String) throws {
        let argv = try descriptor.arguments(model: "sonnet", systemPrompt: "")
        #expect(descriptor.isolationProblems(arguments: argv + [flag]) == ["forbidden:\(flag)"])
        #expect(descriptor.isolationProblems(arguments: argv + ["\(flag)=x"]) == ["forbidden:\(flag)"])
    }

    @Test(arguments: ["--settings", "-c", "--dangerously-skip-permissions", "-"])
    func aPromptThatLooksLikeAFlagIsRefused(prompt: String) {
        #expect(throws: ProviderError.invalidRequest) {
            try descriptor.arguments(model: "sonnet", systemPrompt: prompt)
        }
    }

    @Test func aFlagNameInsideThePromptIsJustText() throws {
        let argv = try descriptor.arguments(model: "sonnet", systemPrompt: "Never use --settings.")
        #expect(descriptor.isolationProblems(arguments: argv).isEmpty)
    }

    @Test func aTooLongOrNulPromptIsRefused() {
        #expect(throws: ProviderError.invalidRequest) {
            try descriptor.arguments(model: "sonnet", systemPrompt: String(repeating: "a", count: 20_000))
        }
        #expect(throws: ProviderError.invalidRequest) {
            try descriptor.arguments(model: "sonnet", systemPrompt: "a\0b")
        }
    }

    // MARK: output

    @Test func parsesASuccess() {
        let json = #"{"type":"result","is_error":false,"result":"Hello."}"#
        #expect(descriptor.parseOutput(Data(json.utf8)) == .answer("Hello."))
    }

    @Test func parsesTheEventArrayForm() {
        let json = #"[{"type":"system"},{"type":"result","is_error":false,"result":"Hi."}]"#
        #expect(descriptor.parseOutput(Data(json.utf8)) == .answer("Hi."))
    }

    @Test func anEmptyResultOrNonJSONIsAFailure() {
        #expect(descriptor.parseOutput(Data(#"{"is_error":false,"result":""}"#.utf8)) == .failure(.other))
        #expect(descriptor.parseOutput(Data("not json".utf8)) == .failure(.other))
        #expect(descriptor.parseOutput(Data()) == .failure(.other))
    }

    @Test func aCutAnswerIsTruncatedWhateverTheSubtype() {
        let json =
            #"{"subtype":"success","is_error":true,"result":"API Error: Claude's response exceeded the 32000 output token maximum."}"#
        #expect(descriptor.parseOutput(Data(json.utf8)) == .truncated)
    }

    @Test func isErrorIsAFailureWhateverTheText() {
        let json = #"{"is_error":true,"result":"All fine, really."}"#
        #expect(descriptor.parseOutput(Data(json.utf8)) == .failure(.other))
    }

    @Test(arguments: [
        (#"{"is_error":true,"result":"Not logged in - Please run /login"}"#, "", ProviderFailure.notSignedIn),
        (#"{"is_error":true,"result":"Claude usage limit reached"}"#, "", .rateLimited),
        (#"{"is_error":true,"result":"fetch failed ENOTFOUND"}"#, "", .network),
        (#"{"is_error":true,"result":"There was an issue with the selected model"}"#, "", .other),
        ("", "error: unknown option '--zzz'", .incompatibleVersion),
        ("", "", .other),
    ])
    func classifiesStdoutAndStderr(stdout: String, stderr: String, expected: ProviderFailure) {
        #expect(descriptor.classify(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), exitCode: 1) == expected)
    }

    // MARK: version and status

    @Test func parsesVersions() {
        #expect(ProviderVersion(parsing: "2.1.328 (Claude Code)")?.parts == [2, 1, 328])
        #expect(ProviderVersion(parsing: "no version here") == nil)
        #expect(ProviderVersion([2, 1, 5]) < ProviderVersion([2, 1, 328]))
        #expect(ProviderVersion([2, 2]) > ProviderVersion([2, 1, 999]))
    }

    @Test func statusFollowsVersionAndLogin() {
        let loggedIn = Data(#"{"loggedIn":true,"email":"nobody@example.invalid"}"#.utf8)
        let out = Data(#"{"loggedIn":false}"#.utf8)
        #expect(descriptor.status(versionOutput: Data("2.1.328 (Claude Code)".utf8), authOutput: loggedIn) == .ready)
        #expect(descriptor.status(versionOutput: Data("2.1.328".utf8), authOutput: out) == .notSignedIn)
        #expect(descriptor.status(versionOutput: Data("2.1.328".utf8), authOutput: nil) == .notSignedIn)
        #expect(descriptor.status(versionOutput: Data("1.9.0".utf8), authOutput: loggedIn) == .incompatibleVersion)
        #expect(descriptor.status(versionOutput: Data("3.0.0".utf8), authOutput: loggedIn) == .incompatibleVersion)
        #expect(descriptor.status(versionOutput: Data("garbage".utf8), authOutput: loggedIn) == .incompatibleVersion)
    }

    @Test func environmentAllowlistKeepsOnlyListedNames() {
        let source = [
            "HOME": "/h", "USER": "u", "CLAUDE_CODE_X": "1", "CLAUDECODE": "1", "ANTHROPIC_MODEL": "m",
            "OTHER": "o", "ANTHROPIC_API_KEY": "k", "HTTPS_PROXY": "p", "PATH": "/evil",
        ]
        let env = ProviderEnvironment.make(from: source, allowlist: descriptor.environmentAllowlist)
        #expect(Set(env.keys) == ["HOME", "USER", "ANTHROPIC_API_KEY", "HTTPS_PROXY", "PATH"])
        #expect(env["PATH"] == ProviderEnvironment.fixedPath)
    }
}
