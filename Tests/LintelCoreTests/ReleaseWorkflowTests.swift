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

    /// The steps of a job: every `      - ` line starts one (the file keeps steps at six spaces of indent).
    private func steps(_ job: String) throws -> [[String]] {
        var result: [[String]] = []
        for line in try #require(try jobs()[job]) {
            if line.hasPrefix("      - ") {
                result.append([line])
            } else if !result.isEmpty {
                result[result.count - 1].append(line)
            }
        }
        return result.map(code)
    }

    /// The step with this `- name:` (exactly one must exist).
    private func step(_ job: String, named name: String) throws -> [String] {
        let found = try steps(job).filter { $0.first == "      - name: \(name)" }
        #expect(found.count == 1, "Exactly one step named '\(name)' in \(job)")
        return try #require(found.first)
    }

    /// The step that uploads this artifact.
    private func uploadStep(_ job: String, artifact: String) throws -> [String] {
        let found = try steps(job).filter { $0.contains("          name: \(artifact)") }
        #expect(found.count == 1, "Exactly one step uploads \(artifact) in \(job)")
        return try #require(found.first)
    }

    /// A safety step must stop the run when it fails and must run on every run it applies to: no
    /// `continue-on-error`, no step-level `if:`, nothing that turns a failing command into success.
    private func expectNotSoftened(_ step: [String], _ label: String) {
        let text = step.joined(separator: "\n")
        #expect(!text.contains("continue-on-error"), "\(label) must not continue on error")
        let conditional = step.contains { $0.hasPrefix("        if:") || $0.hasPrefix("      - if:") }
        #expect(!conditional, "\(label) must have no if:")
        #expect(!text.contains("set +e"), "\(label) must not set +e")
        #expect(text.firstMatch(of: /\|\|\s*(true|:|exit\s+0)\b/) == nil, "\(label) must not swallow a failure with ||")
        #expect(text.firstMatch(of: /;\s*(true|:)\s*$/) == nil, "\(label) must not end in `; true`")
        #expect(!text.contains("shell: "), "\(label) must use the default shell (bash -e)")
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
                "NOTARY_ISSUER_ID", "SPARKLE_ED_PRIVATE_KEY",
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

    @Test func pullRequestsCancelAndTagReleasesQueueInTheJobs() throws {
        let text = code(try workflow().components(separatedBy: "\n")).joined(separator: "\n")
        // Workflow level: per event and ref, cancelling only for pull requests, no queue.
        // The event name keeps a run started by hand out of the group of the builds that follow each push to main.
        #expect(text.contains("\nconcurrency:\n  group: release-${{ github.event_name }}-${{ github.ref }}\n"))
        #expect(text.contains("  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n"))
        #expect(!text.contains("\n  queue: max"))
        // Job level: sign and publish share one queued, never-cancelled group.
        let jobs = try jobs()
        for name in ["sign", "publish"] {
            let job = code(try #require(jobs[name])).joined(separator: "\n")
            #expect(job.contains("    concurrency:\n      group: release-tags\n      queue: max\n"), "\(name)")
            #expect(!job.contains("cancel-in-progress"), "\(name)")
        }
        #expect(!code(try #require(jobs["build"])).joined().contains("release-tags"))
    }

    @Test func signAndPublishNeverRunForPullRequestsOrMainPushes() throws {
        let jobs = try jobs()
        let publish = code(try #require(jobs["publish"]))
        let condition = try #require(publish.first { $0.hasPrefix("    if: ") })
        #expect(condition.contains("github.event_name == 'push'") && condition.contains("refs/tags/v"))
        #expect(!condition.contains("||"))
        // sign: the first alternative is a tag push, the second a manual run on main (checked above).
        let sign = code(try #require(jobs["sign"]))
        let signCondition = try #require(sign.first { $0.hasPrefix("    if: ") })
        #expect(signCondition.components(separatedBy: "||")[0].contains("refs/tags/v"))
    }

    @Test func keepsTheTriggersOfTheMainBranchPush() throws {
        let lines = try workflow().components(separatedBy: "\n")
        let onBlock = code(lines).prefix { $0 != "permissions:" }.joined(separator: "\n")
        #expect(onBlock.contains("  push:\n    tags: [\"v*\"]\n    branches: [main]\n    paths:\n"))
        // The narrowed pull_request list: no Sources/** (ci.yml covers source-only pull requests).
        let pullRequest = try #require(onBlock.components(separatedBy: "  pull_request:\n").last)
        let pullRequestPaths = pullRequest.components(separatedBy: "  workflow_dispatch:")[0]
        #expect(!pullRequestPaths.contains("Sources/**"))
        #expect(pullRequestPaths.contains("Resources/*.entitlements"))
        let build = code(try #require(try jobs()["build"])).joined(separator: "\n")
        #expect(build.contains("if: github.actor != 'dependabot[bot]'"))
        // One step: the condition, a step timeout above the watchdog limit (800 s + samples + kill < 16 min) and the
        // watchdog around swift test.
        #expect(
            build.contains(
                "if: github.event_name != 'push' || startsWith(github.ref, 'refs/tags/')\n"
                    + "        timeout-minutes: 16\n"
                    + "        run: scripts/test-with-watchdog.sh --limit 800 --name test -- swift test\n"))
        #expect(
            build.contains(
                "        if: failure() || cancelled()\n"
                    + "        uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2\n"
                    + "        with:\n"
                    + "          name: test-watchdog\n"
                    + "          path: ${{ runner.temp }}/test-watchdog\n"))
    }

    @Test func notarizationIsBoundedAndItsLogsAreKept() throws {
        let sign = code(try #require(try jobs()["sign"]))
        let text = sign.joined(separator: "\n")
        let minutes = try #require(
            sign.compactMap { $0.firstMatch(of: /^    timeout-minutes: (\d+)$/).map { Int($0.1) ?? 0 } }.first)
        // Two notarizations at 10 + 40 minutes each (scripts/notarize.sh defaults) and the rest must fit.
        #expect(minutes >= 310, "largest allowed app wait (240) + the rest must fit")
        #expect(minutes <= 360)
        let upload = try #require(text.range(of: "name: notary-logs"))
        let before = String(text[..<upload.lowerBound])
        #expect(before.components(separatedBy: "\n").suffix(6).contains { $0.contains("if: always()") })
    }

    @Test func theAppWaitIsAManualInputPassedThroughEnvOnly() throws {
        let text = code(try workflow().components(separatedBy: "\n")).joined(separator: "\n")
        #expect(text.contains("      notary_wait_minutes:\n"))
        #expect(text.contains("        type: string\n        default: \"40\"\n"))
        let sign = code(try #require(try jobs()["sign"]))
        let appStep = try #require(sign.joined(separator: "\n").range(of: "- name: Notarize the app"))
        let dmgStep = try #require(sign.joined(separator: "\n").range(of: "- name: Notarize and staple the DMG"))
        let joined = sign.joined(separator: "\n")
        #expect(
            joined[appStep.lowerBound..<dmgStep.lowerBound].contains(
                "NOTARY_WAIT_MINUTES: ${{ inputs.notary_wait_minutes }}"))
        #expect(!joined[dmgStep.lowerBound...].contains("NOTARY_WAIT_MINUTES"), "the DMG keeps the default wait")
    }

    @Test func signChecksTheReleaseOrderBeforeAnySecret() throws {
        let sign = code(try #require(try jobs()["sign"]))
        let text = sign.joined(separator: "\n")
        let order = try #require(text.range(of: "scripts/check-release-order.sh"))
        let firstSecret = try #require(text.range(of: "secrets."))
        #expect(order.lowerBound < firstSecret.lowerBound)
        #expect(text.contains("fetch-depth: 0"))
    }

    /// The job-level group lets the next tag's `sign` run between this tag's `sign` and `publish`, so `publish` checks
    /// the order again, inside the group, before it creates the release (the spec's "a second tag's ancestry check runs
    /// only after the first tag is published").
    @Test func publishChecksTheReleaseOrderAgainBeforeCreatingTheRelease() throws {
        let jobs = try jobs()
        for name in ["sign", "publish"] {
            let text = code(try #require(jobs[name])).joined(separator: "\n")
            #expect(
                text.contains("run: scripts/check-release-order.sh --github \"$GITHUB_SHA\" \"$GITHUB_REF_NAME\""),
                "\(name)")
        }
        let publish = code(try #require(jobs["publish"])).joined(separator: "\n")
        let order = try #require(publish.range(of: "scripts/check-release-order.sh"))
        let create = try #require(publish.range(of: "gh release create"))
        #expect(order.lowerBound < create.lowerBound)
        #expect(publish.contains("fetch-depth: 0"))
        #expect(publish.contains("persist-credentials: false"))
    }

    // MARK: Appcast (spec Step 4.7)

    @Test func theSparkleKeyExistsOnlyInTheSignJob() throws {
        let jobs = try jobs()
        for name in ["build", "publish"] {
            #expect(
                !(try #require(jobs[name])).joined(separator: "\n").contains("SPARKLE_ED_PRIVATE_KEY"),
                "\(name) must not see the Sparkle key")
        }
        let header = try workflow().components(separatedBy: "\njobs:\n")[0]
        #expect(!code(header.components(separatedBy: "\n")).joined().contains("SPARKLE_ED_PRIVATE_KEY"))
        // In sign the secret is read through env: only, never in a run: text, and nothing traces the shell.
        let sign = code(try #require(jobs["sign"]))
        for line in sign where line.contains("SPARKLE_ED_PRIVATE_KEY") {
            #expect(
                line.trimmingCharacters(in: .whitespaces)
                    == "SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}",
                "The key may only be passed as a step env entry: \(line)")
        }
        #expect(!(try workflow()).contains("set -x"))
        #expect(!(try workflow()).contains("--ed-key-file"), "Only scripts/sparkle-sign.sh calls sign_update")
        let executable = code(try workflow().components(separatedBy: "\n")).joined(separator: "\n")
        #expect(!executable.contains("sign_update"), "Only scripts/sparkle-sign.sh calls sign_update")
    }

    @Test func theKeyPairIsCheckedBeforeAnythingIsSignedOrUploaded() throws {
        let sign = code(try #require(try jobs()["sign"])).joined(separator: "\n")
        let check = try #require(
            sign.range(of: "scripts/sparkle-sign.sh check-key dist/Lintel.app/Contents/Info.plist"))
        let firstUpload = try #require(sign.range(of: "actions/upload-artifact@"))
        let importCertificate = try #require(sign.range(of: "- name: Import the Developer ID certificate"))
        let notarize = try #require(sign.range(of: "scripts/notarize.sh"))
        let signDMG = try #require(sign.range(of: "scripts/release-appcast.sh"))
        #expect(check.lowerBound < importCertificate.lowerBound)
        #expect(check.lowerBound < notarize.lowerBound)
        #expect(check.lowerBound < signDMG.lowerBound)
        #expect(check.lowerBound < firstUpload.lowerBound)
        // The tools are fetched (checksum-verified) before the check and nothing else installs them.
        let fetch = try #require(sign.range(of: "scripts/fetch-sparkle-tools.sh"))
        #expect(fetch.lowerBound < check.lowerBound)
        // publish only runs after sign succeeded, which includes the check.
        #expect(try workflow().contains("    needs: [build, sign]"))
    }

    @Test func theFeedIsBuiltSignedAndVerifiedBeforeItIsUploaded() throws {
        let sign = code(try #require(try jobs()["sign"])).joined(separator: "\n")
        let order = [
            "scripts/fetch-previous-appcast.sh appcast \"$FEED_TAG\"",
            "scripts/release-appcast.sh dist/Lintel.app/Contents/Info.plist dist/Lintel.dmg appcast",
            "name: Lintel-appcast",
        ]
        var position = sign.startIndex
        for item in order {
            let found = try #require(sign.range(of: item, range: position..<sign.endIndex), "\(item) out of order")
            position = found.upperBound
        }
        // The feed is made from the finished DMG: after the checksum and the bundle verification.
        let checksum = try #require(sign.range(of: "- name: Checksum"))
        let verify = try #require(sign.range(of: "- name: Verify the signed, notarized bundle"))
        let make = try #require(sign.range(of: "scripts/release-appcast.sh"))
        #expect(checksum.lowerBound < make.lowerBound && verify.lowerBound < make.lowerBound)
        // The signing, building and verifying happen inside the script; the workflow holds none of them.
        for gone in ["make-appcast.sh", "verify-feed", "sign-feed", "sign-file", "xmllint"] {
            #expect(!sign.contains(gone), "\(gone) belongs in scripts/release-appcast.sh, which the tests run")
        }
    }

    /// The reviewer softened these steps one at a time (`continue-on-error`, `|| true`, an emptied argument, `if: false`) and
    /// every text check still passed. Their bodies live in scripts that `scripts/tests/test_appcast.zsh` runs with real
    /// signing and stub `gh`; here the steps must stay bare calls that cannot be skipped or ignored.
    @Test func theSafetyStepsCannotBeSkippedOrSoftened() throws {
        let checkKey = try step("sign", named: "Check the Sparkle signing key against the app's public key")
        let fetchPrevious = try step("sign", named: "Fetch the previous appcast")
        let buildFeed = try step("sign", named: "Sign the DMG and build the appcast")
        let fetchTools = try step("sign", named: "Fetch the Sparkle tools")
        let guardStep = try step("publish", named: "Check the appcast is built on the newest release")
        let orderPublish = try step("publish", named: "Check the release order again")
        for (label, step) in [
            ("check-key", checkKey), ("fetch-previous", fetchPrevious), ("sign and verify the feed", buildFeed),
            ("fetch tools", fetchTools), ("publish guard", guardStep), ("release order in publish", orderPublish),
        ] {
            expectNotSoftened(step, label)
        }
        // Each is exactly one call of its script (nothing before or after it that could change the exit status).
        #expect(checkKey.contains("        run: scripts/sparkle-sign.sh check-key dist/Lintel.app/Contents/Info.plist"))
        #expect(
            fetchPrevious.contains("        run: scripts/fetch-previous-appcast.sh appcast \"$FEED_TAG\""))
        #expect(
            fetchPrevious.contains(
                "          FEED_TAG: ${{ startsWith(github.ref, 'refs/tags/') && github.ref_name || '' }}"),
            "A tag run must pass its tag")
        #expect(
            buildFeed.contains(
                "        run: scripts/release-appcast.sh dist/Lintel.app/Contents/Info.plist dist/Lintel.dmg appcast"))
        #expect(
            guardStep.contains(
                "        run: scripts/check-appcast-base.sh appcast/previous-tag.txt \"$GITHUB_REF_NAME\""))
        for step in [checkKey, fetchPrevious, buildFeed, guardStep] {
            let runs = step.filter { $0.hasPrefix("        run:") }
            #expect(runs.count == 1 && !(runs[0].contains("|") || runs[0].contains("&") || runs[0].contains(";")))
        }
        // The exit status of the tools fetch is not lost in a command substitution inside another command.
        let fetchText = fetchTools.joined(separator: "\n")
        #expect(fetchText.contains("SIGN_UPDATE=\"$(scripts/fetch-sparkle-tools.sh \"$RUNNER_TEMP/sparkle\")\""))
        #expect(!fetchTools.contains { $0.contains("echo") && $0.contains("fetch-sparkle-tools.sh") })
        // Nothing anywhere in the workflow may continue on error.
        #expect(!(try workflow()).contains("continue-on-error"))
        // The key is in exactly these two steps and in no other.
        let withKey = try steps("sign").filter { $0.joined().contains("SPARKLE_ED_PRIVATE_KEY") }
        #expect(withKey == [checkKey, buildFeed])
    }

    @Test func theScriptsBehindTheSafetyStepsNeverSwallowAFailure() throws {
        for name in [
            "release-appcast.sh", "fetch-previous-appcast.sh", "check-appcast-base.sh", "previous-release.sh",
            "sparkle-sign.sh", "fetch-sparkle-tools.sh", "make-appcast.sh",
        ] {
            let text = try String(contentsOf: Self.root.appending(path: "scripts/\(name)"), encoding: .utf8)
            let body = code(text.components(separatedBy: "\n")).joined(separator: "\n")
            #expect(body.firstMatch(of: /\|\|\s*(true|:)\b/) == nil, "\(name) must not swallow a failure")
            #expect(!body.contains("set +e"), "\(name) must not set +e")
            let failsOnError = body.contains("set -euo pipefail") || body.contains("set -uo pipefail")
            #expect(failsOnError, "\(name) must fail on errors")
        }
    }

    /// A manual signed run builds, signs and verifies the feed (that exercises the secret) but must not upload it: it is a
    /// feed for 0.0.0 validly signed with the production key.
    @Test func aManualRunDoesNotUploadTheFeed() throws {
        let upload = try uploadStep("sign", artifact: "Lintel-appcast")
        #expect(upload.contains("        if: startsWith(github.ref, 'refs/tags/')"))
        // No other step may upload anything from the feed's folder.
        let others = try steps("sign").filter { $0 != upload && $0.joined().contains("actions/upload-artifact@") }
        for other in others { #expect(!other.joined().contains("appcast/")) }
        // The script that builds the feed removes it itself on a run that is not a tag run.
        let script = try String(
            contentsOf: Self.root.appending(path: "scripts/release-appcast.sh"), encoding: .utf8)
        #expect(script.contains("rm -f \"$STAGE/appcast.xml\" \"$WORK/appcast.xml\""))
    }

    @Test func publishAttachesTheFeedAndChecksItWasBuiltOnTheNewestRelease() throws {
        let publish = code(try #require(try jobs()["publish"])).joined(separator: "\n")
        #expect(publish.contains("name: Lintel-appcast"))
        let create = try #require(publish.range(of: "gh release create"))
        let upload = String(publish[create.lowerBound...])
        #expect(upload.contains("appcast/appcast.xml"))
        let guardStep = try #require(publish.range(of: "scripts/check-appcast-base.sh"))
        #expect(guardStep.lowerBound < create.lowerBound)
        // The poll of the live feed only warns, runs after the release and has no condition that could skip it.
        let poll = try step("publish", named: "Wait for the site to serve the new feed")
        let pollText = poll.joined(separator: "\n")
        #expect(pollText.contains("scripts/wait-for-site-feed.sh appcast/appcast.xml --deadline 600 --interval 30"))
        #expect(!poll.contains { $0.hasPrefix("        if:") }, "The poll also runs without a dispatch (it warns)")
        #expect(!pollText.contains("continue-on-error"))
        let pollPosition = try #require(publish.range(of: "scripts/wait-for-site-feed.sh"))
        #expect(pollPosition.lowerBound > create.lowerBound)
    }

    /// Without the dispatch token the site is not asked to rebuild: that is a warning with what to do, never silence
    /// and never a failure.
    @Test func aMissingDispatchTokenIsAWarningNotSilence() throws {
        let rebuild = try step("publish", named: "Rebuild the website").joined(separator: "\n")
        let branch = try #require(rebuild.range(of: "if [[ -z \"$GH_TOKEN\" ]]; then"))
        let end = try #require(rebuild.range(of: "exit 0", range: branch.upperBound..<rebuild.endIndex))
        let text = String(rebuild[branch.upperBound..<end.lowerBound])
        #expect(text.contains("::warning::"))
        #expect(text.contains("by hand"))
        #expect(text.contains("https://lintelapp.com/appcast.xml"))
        let script = try String(
            contentsOf: Self.root.appending(path: "scripts/wait-for-site-feed.sh"), encoding: .utf8)
        #expect(script.contains("::warning::The website was not asked to rebuild"))
        #expect(script.contains("exit 0"))
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
