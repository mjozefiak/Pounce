import Foundation
import Testing

/// Structural safety properties of `.github/workflows/release.yml` (updates and open-source hygiene spec, Step 2.3).
/// The release workflow is the only place where the Developer ID key meets the network, so what must hold is checked
/// on the text of the file: no YAML library is needed because the file keeps one shape (two-space indents).
@Suite struct ReleaseWorkflowTests {
    private static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func workflow() throws -> String {
        try String(
            contentsOf: Self.root.appending(path: ".github/workflows/release.yml"), encoding: .utf8)
    }

    /// The text of each job under `jobs:`, keyed by job id (a line `  name:` at two spaces of indent).
    private func jobs() throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current: String?
        var inJobs = false
        for line in try workflow().components(separatedBy: "\n") {
            if line == "jobs:" {
                inJobs = true
                continue
            }
            guard inJobs else { continue }
            if let match = line.firstMatch(of: /^  ([a-z][a-z0-9_-]*):\s*$/) {
                current = String(match.1)
                result[current!] = []
            } else if let current {
                result[current, default: []].append(line)
            }
        }
        return result
    }

    private func code(_ lines: [String]) -> [String] {
        lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    @Test func hasThreeJobs() throws {
        #expect(Set(try jobs().keys) == ["build", "sign", "publish"])
    }

    @Test func signIsTheOnlyJobWithAnEnvironment() throws {
        let all = code(try workflow().components(separatedBy: "\n"))
        let environmentLines = all.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("environment:") }
        #expect(environmentLines.count == 1, "Exactly one job may name an Environment (publish comes with Step 2.4)")
        let sign = code(try #require(try jobs()["sign"]))
        #expect(sign.contains { $0 == "    environment: release" })
    }

    @Test func signCannotRunForAPullRequest() throws {
        let sign = code(try #require(try jobs()["sign"]))
        let condition = try #require(
            sign.first { $0.hasPrefix("    if: ") }, "The sign job needs an if: condition")
        let expression = String(condition.dropFirst("    if: ".count))
        #expect(!expression.contains("pull_request"))
        #expect(!expression.contains(" ( "), "No grouping: the || split below must be exact")
        #expect(!expression.contains("(("), "No grouping: the || split below must be exact")
        // `&&` binds tighter than `||`: every alternative must name an event that is not a pull request.
        let alternatives = expression.components(separatedBy: "||")
        #expect(alternatives.count == 2)
        for alternative in alternatives {
            let names =
                alternative.contains("github.event_name == 'push'")
                || alternative.contains("github.event_name == 'workflow_dispatch'")
            #expect(names, "Alternative without an event_name guard: \(alternative)")
        }
        // A tag push, or a manual run with the sign input on main.
        #expect(alternatives[0].contains("github.event_name == 'push'") && alternatives[0].contains("refs/tags/v"))
        #expect(alternatives[1].contains("inputs.sign == true") && alternatives[1].contains("refs/heads/main"))
        #expect(sign.contains { $0 == "    needs: build" })
    }

    @Test func signUsesOnlyFirstPartyActions() throws {
        let sign = code(try #require(try jobs()["sign"]))
        let uses = sign.compactMap { line -> String? in
            guard let match = line.firstMatch(of: /^\s*(?:- )?uses:\s*(\S+)/) else { return nil }
            return String(match.1)
        }
        #expect(!uses.isEmpty)
        for action in uses {
            #expect(
                action.hasPrefix("actions/checkout@") || action.hasPrefix("actions/download-artifact@")
                    || action.hasPrefix("actions/upload-artifact@"),
                "Third-party or unexpected action in the sign job: \(action)")
        }
    }

    @Test func signCompilesAndTestsNothing() throws {
        let text = code(try #require(try jobs()["sign"])).joined(separator: "\n")
        for forbidden in ["swift test", "swift build", "swift package", "xcodebuild -scheme", "setup-xcode"] {
            #expect(!text.contains(forbidden), "The sign job must not contain: \(forbidden)")
        }
    }

    @Test func secretsStayInTheirJobs() throws {
        let jobs = try jobs()
        #expect(!code(try #require(jobs["build"])).joined().contains("secrets."))
        let signSecrets = Set(
            code(try #require(jobs["sign"])).flatMap { line in
                line.matches(of: /secrets\.([A-Z0-9_]+)/).map { String($0.1) }
            })
        #expect(
            signSecrets == [
                "DEVELOPER_ID_P12", "DEVELOPER_ID_P12_PASSWORD", "NOTARY_KEY_P8", "NOTARY_KEY_ID",
                "NOTARY_ISSUER_ID",
            ])
        let publishSecrets = code(try #require(jobs["publish"])).joined().matches(of: /secrets\.([A-Z0-9_]+)/)
            .map { String($0.1) }
        #expect(Set(publishSecrets) == ["LINTEL_WEB_DISPATCH_TOKEN"])
    }

    @Test func noOldSigningSecretOrIdentityIsLeft() throws {
        let text = try workflow()
        for gone in ["SIGNING_P12", "HAS_SIGNING_SECRETS", "Lintel Release", "self-signed", "Second build keeps"] {
            #expect(!text.contains(gone), "release.yml still mentions: \(gone)")
        }
    }

    @Test func noExpressionIsInterpolatedIntoRunText() throws {
        var offenders: [String] = []
        var runIndent: Int?
        for line in try workflow().components(separatedBy: "\n") {
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = runIndent {
                if trimmed.isEmpty { continue }
                if indent > current {
                    if trimmed.contains("${{") { offenders.append(trimmed) }
                    continue
                }
                runIndent = nil
            }
            if trimmed.hasPrefix("run:") || trimmed.hasPrefix("- run:") {
                if trimmed.contains("${{") { offenders.append(trimmed) }
                runIndent = indent
            }
        }
        #expect(offenders.isEmpty, "Pass expressions through env:, not run: text: \(offenders)")
    }

    @Test func tagRunsQueueAndNeverCancel() throws {
        let text = code(try workflow().components(separatedBy: "\n")).joined(separator: "\n")
        #expect(text.contains("\n  queue: max\n"))
        #expect(!text.contains("cancel-in-progress"), "queue: max cannot be combined with cancel-in-progress: true")
        #expect(text.contains("'release-tags'"))
    }

    @Test func entitlementsFilesDifferOnlyInLibraryValidation() throws {
        func entitlements(_ name: String) throws -> [String: Any] {
            let data = try Data(contentsOf: Self.root.appending(path: "Resources/\(name)"))
            return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
        let teamID = try entitlements("Lintel.entitlements")
        let adhoc = try entitlements("Lintel-adhoc.entitlements")
        let key = "com.apple.security.cs.disable-library-validation"
        #expect(teamID[key] == nil)
        #expect(adhoc[key] as? Bool == true)
        #expect(teamID["com.apple.security.device.audio-input"] as? Bool == true)
        #expect(adhoc["com.apple.security.device.audio-input"] as? Bool == true)
        #expect(Set(adhoc.keys).subtracting([key]) == Set(teamID.keys))
    }
}
