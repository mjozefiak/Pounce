import Foundation
import LintelSpeech

@testable import LintelProviders

/// Invented text only. No real meeting, dictation or person appears in this target's tests.
let syntheticCanary = "zebra-quartz-7041"

struct TempDir {
    let url: URL

    init() throws {
        url = URL(filePath: NSTemporaryDirectory()).appending(path: "lintel-providers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

struct FixedLocator: ProviderLocating {
    let url: URL?
    func locate(_ descriptor: ProviderDescriptor, manualPath: String?) -> URL? { url }
}

/// A fake `claude`: a shell script that records what it was given into files next to it. `mode` (a file) picks the
/// behaviour, so no real CLI and no network is involved.
struct FakeCLI {
    let dir: URL
    var script: URL { dir.appending(path: "claude") }
    var configDir: URL { dir.appending(path: "config", directoryHint: .isDirectory) }

    init(in dir: URL, mode: String = "ok") throws {
        self.dir = dir
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data(Self.source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        setMode(mode)
    }

    func setMode(_ mode: String) {
        try? Data(mode.utf8).write(to: dir.appending(path: "mode"))
    }

    /// Lets a `gated` run finish (the fake waits for this file, at most a minute, so a broken test cannot hang it).
    func release() {
        try? Data().write(to: dir.appending(path: "release"))
    }

    func read(_ name: String) -> String {
        (try? String(contentsOf: dir.appending(path: name), encoding: .utf8)) ?? ""
    }

    /// One entry per line; empty lines are kept (an empty argument is a line), the final newline is not an entry.
    func lines(_ name: String) -> [String] {
        var parts = read(name).components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// The environment of the test process as the runner sees it: allowed names, junk names that must not pass.
    func sourceEnvironment() -> [String: String] {
        [
            "HOME": dir.appending(path: "home").path, "USER": "tester", "LANG": "en_US.UTF-8",
            "CLAUDE_CONFIG_DIR": configDir.path, "HTTPS_PROXY": "http://127.0.0.1:9",
            "CLAUDE_CODE_SOMETHING": "1", "CLAUDECODE": "1", "CLAUDE_FAKE_FLAG": "1", "ANTHROPIC_MODEL": "x",
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:1", "SECRET_TOKEN": "nope", "ANTHROPIC_API_KEY": "synthetic-key",
        ]
    }

    static let source = #"""
        #!/bin/bash
        here="$(cd "$(dirname "$0")" && pwd)"
        mode="$(cat "$here/mode")"
        if [ "$1" = "--version" ]; then echo "2.1.328 (Claude Code)"; exit 0; fi
        if [ "$1" = "auth" ]; then
          if [ "$mode" = "loggedout" ]; then echo '{"loggedIn":false}'; else echo '{"loggedIn":true,"email":"nobody@example.invalid"}'; fi
          exit 0
        fi
        if [ "$mode" = "escape" ]; then
          # A grandchild that leaves the process group (new session) and keeps stdin, stdout and stderr open. It lives
          # far longer than any limit a test waits for, so only the runner can end the run, never the grandchild.
          perl -e 'use POSIX qw(setsid); setsid(); open(my $f, ">", $ARGV[0]); close $f; sleep 120' "$here/escaped" &
          echo $! > "$here/escapedpid"
          while [ ! -e "$here/escaped" ]; do sleep 0.05; done
          echo '{"type":"result","is_error":false,"result":"Fake answer."}'
          exit 0
        fi
        printf '%s\n' "$@" > "$here/argv"
        env | cut -d= -f1 | sort > "$here/envnames"
        env | grep '^USER=' > "$here/userenv"
        pwd > "$here/cwd"
        ls -A . > "$here/cwdlist"
        stat -f %Lp . > "$here/cwdmode"
        stdin="$(cat)"
        printf '%s' "$stdin" > "$here/stdin"
        case " $* " in
          *" --no-session-persistence "*) ;;
          *) mkdir -p "$CLAUDE_CONFIG_DIR/projects/p"; printf '%s' "$stdin" > "$CLAUDE_CONFIG_DIR/projects/p/s.jsonl";;
        esac
        case "$mode" in
          ok) echo '{"type":"result","subtype":"success","is_error":false,"result":"Fake answer.","usage":{"input_tokens":3,"output_tokens":2}}';;
          gated) i=0; while [ ! -e "$here/release" ] && [ $i -lt 1200 ]; do sleep 0.05; i=$((i+1)); done
            echo '{"type":"result","is_error":false,"result":"slow answer"}';;
          slow) sleep 1; echo '{"type":"result","is_error":false,"result":"slow answer"}';;
          hang) sleep 30;;
          child) sleep 60 & echo $! > "$here/childpid"; wait;;
          bigout) head -c 2000000 /dev/zero | tr '\0' 'a';;
          login) echo '{"type":"result","is_error":true,"result":"Not logged in - Please run /login"}'; exit 1;;
          rate) echo '{"type":"result","is_error":true,"result":"Claude usage limit reached"}'; exit 1;;
          trunc) echo '{"type":"result","subtype":"success","is_error":true,"result":"API Error: Claude'"'"'s response exceeded the 32000 output token maximum."}'; exit 1;;
          badflag) echo "error: unknown option '--zzz' $stdin" >&2; exit 1;;
          nosafemode) case " $* " in *" --safe-mode "*) echo "error: unknown option '--safe-mode'" >&2; exit 1;; esac
            echo '{"type":"result","is_error":false,"result":"Fake answer."}';;
          exit3) echo "boom $stdin" >&2; exit 3;;
          empty) echo '{"type":"result","is_error":false,"result":""}';;
        esac
        """#
}

/// Waits for a state, never for a duration: the timeout is only a generous guard against a hang.
func eventually(timeout: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

/// The same wait for a condition that has to be read asynchronously (an actor's state).
func eventuallyAsync(timeout: Double = 30, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A runner over the fake binary and the real process runner, with a descriptor that passed the (fake) canary.
func makeRunner(_ cli: FakeCLI, caches: URL, gate: ProviderGate = ProviderGate()) -> ProviderRunner {
    ProviderRunner(
        system: ProviderSystem(locator: FixedLocator(url: cli.script), process: LiveProviderProcess()),
        descriptors: [ProviderDescriptor.claudeCode.with(isolationVerified: true)],
        cachesDirectory: caches, gate: gate, environment: { cli.sourceEnvironment() })
}

func makeRequest(model: String = "sonnet", timeout: Duration = .seconds(20)) -> ProviderRequest {
    ProviderRequest(
        feature: .meetingsNotes, model: model,
        messages: [
            ChatMessage(role: "system", content: "Write short notes."),
            ChatMessage(role: "user", content: "Transcript: \(syntheticCanary) said hello."),
        ], timeout: timeout)
}

let allowed: ProviderAuthorization = { .allowed }

final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var value: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
}
