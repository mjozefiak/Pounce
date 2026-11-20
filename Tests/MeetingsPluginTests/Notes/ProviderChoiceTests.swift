import Foundation
import LintelKit
import LintelSpeech
import LintelTestSupport
import Testing

@testable import LintelProviders
@testable import MeetingsPlugin

/// The "Notes are written by" choice (mockup v2, owner decisions D5 to D15 of 2026-11-20). Fake process, fake
/// pasteboard, no real CLI.
@MainActor
@Suite struct ProviderChoiceTests {
    private func rig(_ settings: [String: SettingValue] = ["plugins.meetings.notesEnabled": .bool(true)]) throws
        -> (notes: NotesServiceRig, choice: ProviderChoiceRig)
    {
        let notes = try NotesServiceRig(settings: settings)
        return (notes, ProviderChoiceRig(settings: notes.settings, service: notes.service))
    }

    // MARK: Models (D15)

    @Test func claudeCodeOffersSonnetOpusAndFableAndHidesHaiku() {
        let models = ProviderDescriptor.claudeCode.models
        #expect(models.map(\.id) == ["sonnet", "opus", "fable"])
        #expect(ProviderDescriptor.claudeCode.defaultModelID == "sonnet")
        #expect(models.filter(\.heavier).map(\.id) == ["opus", "fable"])
    }

    @Test func aStoredHiddenModelStillShowsAsItIs() throws {
        let (notes, choice) = try rig([
            "plugins.meetings.notesProvider": .string("claude-code"),
            "plugins.meetings.notesProviderModel": .string("haiku"),
        ])
        _ = notes
        choice.model.reload()
        #expect(choice.model.model?.displayName == "haiku")
        #expect(!choice.model.models.contains { $0.id == "haiku" })
    }

    // MARK: Choosing (consent = the choice, no window)

    @Test func choosingAProviderWritesTheChoiceWithTheNoticeVersionAndNothingElse() throws {
        let (notes, choice) = try rig()
        choice.model.choose(.claudeCode)
        #expect(notes.settings.notesProviderSelection == NotesProviderSelection(provider: .claudeCode, model: "sonnet"))
        #expect(notes.settings.notesProviderInfoVersion == NotesProviderInfo.currentVersion)
        #expect(choice.model.chosen?.id == .claudeCode)
    }

    @Test func changingTheModelAsksNothingAndKeepsTheVersionTheUserSaw() throws {
        let (notes, choice) = try rig()
        notes.settings.setNotesProvider(NotesProviderSelection(provider: .claudeCode, model: "sonnet"), infoVersion: 0)
        choice.model.reload()
        choice.model.chooseModel("opus")
        #expect(notes.settings.notesProviderSelection?.model == "opus")
        #expect(notes.settings.notesProviderInfoVersion == 0)
        #expect(choice.model.showsHeavierNote)
        choice.model.chooseModel("not-offered")
        #expect(notes.settings.notesProviderSelection?.model == "opus")
    }

    @Test func useLocalRemovesEveryKey() throws {
        let (notes, choice) = try rig()
        choice.model.choose(.claudeCode)
        choice.model.useLocal()
        #expect(notes.settings.notesProviderSelection == nil)
        #expect(notes.settings.notesProviderInfoVersion == nil)
        #expect(choice.model.isLocal)
    }

    @Test func useLocalAsksOnceWhileAJobRunsAndTheAnswerIsKept() throws {
        let (notes, choice) = try rig()
        choice.model.choose(.claudeCode)
        notes.service.board.update { $0.phases[1] = .mapping(done: 0, total: 1) }
        choice.model.useLocal()
        #expect(choice.model.confirmingUseLocal)
        #expect(notes.settings.notesProviderSelection != nil)
        choice.model.cancelUseLocal()
        #expect(notes.settings.notesProviderSelection != nil)
        choice.model.useLocal()
        choice.model.confirmUseLocal()
        #expect(notes.settings.notesProviderSelection == nil)
    }

    // MARK: Processes without a chosen provider (none)

    @Test func noProbeAndNoTestRunWhileLocalIsChosen() async throws {
        let (_, choice) = try rig()
        choice.model.refreshStatus()
        choice.model.testProvider()
        try await Task.sleep(for: .milliseconds(30))
        #expect(choice.probes.withLock { $0 } == 0)
        #expect(choice.tryOuts.withLock { $0 }.isEmpty)
    }

    @Test func choosingAProviderChecksItOnceAndRecordsTheVersion() async throws {
        let (_, choice) = try rig()
        choice.model.choose(.claudeCode)
        #expect(await waitFor("the check") { choice.model.status == .ready })
        #expect(choice.probes.withLock { $0 } == 1)
        #expect(choice.model.version == "2.1.329")
    }

    @Test func aCheckThatFindsNoProblemEndsAFailureThatWasOnlyAboutTheCLI() async throws {
        let (notes, choice) = try rig()
        choice.model.choose(.claudeCode)
        notes.service.board.update {
            $0.providerFailure = ProviderJobFailure(reason: .notSignedIn, meetingID: 1, title: nil, startedAt: Date())
        }
        choice.model.reload()
        choice.model.refreshStatus()
        #expect(await waitFor("the failure is cleared") { choice.model.failure == nil })
    }

    @Test func tryItSendsTheFixedExampleOnlyForTheChosenModel() async throws {
        let (_, choice) = try rig()
        choice.model.choose(.claudeCode)
        choice.model.chooseModel("opus")
        choice.model.testProvider()
        #expect(await waitFor("the test") { choice.model.testState == .worked })
        #expect(choice.tryOuts.withLock { $0 } == ["opus"])
    }

    @Test func installPageAndLoginCommandNeedNoProcess() throws {
        let (_, choice) = try rig()
        choice.model.choose(.claudeCode)
        choice.model.openInstallPage()
        choice.model.copyLoginCommand()
        #expect(choice.urls.withLock { $0 }.first?.host == "code.claude.com")
        #expect(choice.copied.withLock { $0 } == ["claude auth login"])
    }

    @Test func chooseFileStoresThePathAndChecksAgain() async throws {
        let (notes, choice) = try rig()
        choice.model.choose(.claudeCode)
        choice.pickedFile.withLock { $0 = URL(filePath: "/opt/tools/claude") }
        choice.model.chooseBinary()
        #expect(notes.settings.notesProviderBinary == "/opt/tools/claude")
    }

    // MARK: Failures

    private func runFailing(_ output: ProviderProcessOutput) async throws -> (NotesServiceRig, Int64) {
        let process = CountingProviderProcess { _, _ in output }
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let id = try await rig.addMeeting()
        rig.library.meetingReady(id)
        #expect(await rig.settle())
        return (rig, id)
    }

    @Test func aSignedOutCLIGivesTheSignInReason() async throws {
        let (rig, id) = try await runFailing(
            ProviderFixtures.output(answer: "Not logged in · Please run /login", isError: true))
        let failure = rig.service.board.snapshot.providerFailure
        #expect(failure?.reason == .notSignedIn)
        #expect(failure?.meetingID == id)
    }

    @Test func aModelOutsideThePlanGivesItsOwnReason() async throws {
        let (rig, _) = try await runFailing(
            ProviderFixtures.output(answer: "Claude Opus is not available with the Claude Pro plan.", isError: true))
        #expect(rig.service.board.snapshot.providerFailure?.reason == .modelNotAvailable)
    }

    @Test func writeOnThisMacUsesTheBuiltInModelOnceAndSendsNothing() async throws {
        let process = CountingProviderProcess { _, _ in
            ProviderFixtures.output(answer: "Not logged in", isError: true)
        }
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let id = try await rig.addMeeting()
        rig.library.meetingReady(id)
        #expect(await rig.settle())
        let sent = process.contentRuns
        rig.service.writeOnThisMac(id)
        #expect(await rig.settle())
        #expect(process.contentRuns == sent, "the second write started no provider process")
        #expect(rig.service.board.snapshot.providerFailure == nil)
        let record = try rig.record(id)
        #expect(record.provider == nil)
        // The setting is not changed by this one write.
        #expect(rig.settings.notesProviderSelection != nil)
    }

    // MARK: The mark keeps the exact model

    @Test func theMarkKeepsTheExactModelTheCLIReported() async throws {
        let process = CountingProviderProcess { _, _ in
            ProviderFixtures.output(
                answer: ProviderFixtures.draft, modelUsage: ["claude-sonnet-5-5": ["inputTokens": 1]])
        }
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let id = try await rig.addMeeting()
        rig.library.meetingReady(id)
        #expect(await rig.settle())
        let record = try rig.record(id)
        #expect(record.provider == "claude-code")
        #expect(record.providerModel == "claude-sonnet-5-5")
    }

    @Test func theMarkKeepsTheAliasWhenTheResultNamesNoModel() async throws {
        let process = CountingProviderProcess(answer: ProviderFixtures.draft)
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let id = try await rig.addMeeting()
        rig.library.meetingReady(id)
        #expect(await rig.settle())
        #expect(try rig.record(id).providerModel == "sonnet")
    }

    @Test func exactModelNeedsExactlyOneValidKey() {
        let d = ProviderDescriptor.claudeCode
        func data(_ usage: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: ["result": "x", "modelUsage": usage])) ?? Data()
        }
        #expect(d.exactModel(stdout: data(["claude-opus-5-5": [:]])) == "claude-opus-5-5")
        #expect(d.exactModel(stdout: data([:])) == nil)
        #expect(d.exactModel(stdout: data(["a": [:], "b": [:]])) == nil)
        #expect(d.exactModel(stdout: data(["bad id; rm": [:]])) == nil)
    }
}

@Suite struct ProviderMarkTests {
    @Test func theChipIsShortAndDetailsHoldTheExactId() {
        #expect(ProviderMark.chip(provider: "claude-code", model: "claude-opus-5-5") == "Sent to: Claude · Opus")
        #expect(ProviderMark.detail(provider: "claude-code", model: "claude-opus-5-5") == "Claude · claude-opus-5-5")
        #expect(ProviderMark.chip(provider: "claude-code", model: "sonnet") == "Sent to: Claude · Sonnet")
        #expect(ProviderMark.chip(provider: "claude-code", model: nil) == "Sent to: Claude")
        #expect(ProviderMark.chip(provider: nil, model: "sonnet") == nil)
        #expect(ProviderMark.chip(provider: "unknown-cli", model: "x") == nil)
    }

    @Test func aMeetingWithoutAMarkClaimsNothing() {
        let entry = MeetingLibraryEntry(
            id: 1, startedAt: Date(), durationMs: 1000, title: nil, sourceBundleID: nil, status: .ready,
            notesStatus: .ok, hasNotes: true)
        #expect(MeetingLibraryPresentation.badge(entry) == "Notes")
        var marked = entry
        marked.notesProvider = "claude-code"
        marked.notesProviderModel = "claude-sonnet-5-5"
        #expect(MeetingLibraryPresentation.badge(marked) == "Sent to: Claude · Sonnet")
        var failed = marked
        failed.notesStatus = .failed
        #expect(MeetingLibraryPresentation.badge(failed) == "Notes failed")
    }
}

@MainActor
@Suite struct ProviderBannerTests {
    private let actions = ProviderBannerActions(
        useLocal: {}, install: {}, chooseFile: {}, checkAgain: {}, update: {}, updateLintel: {}, chooseModel: {},
        writeOnThisMac: {}, retry: {})

    private func input(
        check: ProviderChoiceModel.Check = .known(.ready), failure: ProviderJobFailure.Reason? = nil,
        running: Bool = false
    ) -> ProviderBannerInput {
        ProviderBannerInput(
            providerName: "Claude Code", recipient: "Anthropic", modelName: "Opus", check: check,
            failure: failure.map { ProviderJobFailure(reason: $0, meetingID: 1, title: nil, startedAt: Date()) },
            jobRunning: running)
    }

    private func titles(_ status: SettingsStatus) -> [String] { status.fix.map { String(localized: $0.title) } }

    @Test func readyAndWritingOfferUseLocal() {
        let ready = ProviderStatusBanner.status(input(), actions: actions)
        #expect(ready.level == .ok && titles(ready) == ["Use Local"])
        let writing = ProviderStatusBanner.status(input(running: true), actions: actions)
        #expect(writing.level == .neutral && titles(writing) == ["Use Local"])
    }

    @Test func theStatesOfTheCLIEachHaveTheirButtons() {
        #expect(
            titles(ProviderStatusBanner.status(input(check: .known(.notInstalled)), actions: actions)) == [
                "How to Install", "Choose File…",
            ])
        #expect(
            titles(ProviderStatusBanner.status(input(check: .known(.notSignedIn)), actions: actions)) == ["Check Again"]
        )
        #expect(
            titles(ProviderStatusBanner.status(input(check: .known(.incompatibleVersion)), actions: actions)) == [
                "Update Claude Code", "Check Again",
            ])
        #expect(
            titles(ProviderStatusBanner.status(input(check: .known(.newerVersion)), actions: actions)) == [
                "Update Lintel"
            ])
    }

    @Test func everyFailedJobOffersTheBuiltInModelWithoutSwitchingAnything() {
        for reason in [ProviderJobFailure.Reason.timedOut, .network, .rateLimited, .other] {
            let status = ProviderStatusBanner.status(input(failure: reason), actions: actions)
            #expect(status.level == .error)
            #expect(titles(status) == ["Write on This Mac", "Try Again"], "\(reason)")
        }
        let long = ProviderStatusBanner.status(input(failure: .tooLong), actions: actions)
        #expect(titles(long) == ["Write on This Mac"])
        let plan = ProviderStatusBanner.status(input(failure: .modelNotAvailable), actions: actions)
        #expect(titles(plan) == ["Choose Model"])
    }

    @Test func aNewerCheckBeatsAnOlderFailure() {
        let status = ProviderStatusBanner.status(
            input(check: .known(.notSignedIn), failure: .timedOut), actions: actions)
        #expect(titles(status) == ["Check Again"])
    }
}
