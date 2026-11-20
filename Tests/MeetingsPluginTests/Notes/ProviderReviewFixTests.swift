import Foundation
import LintelKit
import LintelSpeech
import LintelTestSupport
import Testing

@testable import LintelProviders
@testable import MeetingsPlugin

/// Review of PR 215 (B1 to B3, M1, M2, M4). Fake process, nothing real starts.
@MainActor
@Suite struct ProviderReviewFixTests {
    private static let root: URL = {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }()

    // MARK: B1 the notice is visible whenever a provider can be sent to

    @Test func theProviderIsShownWithAutomaticNotesOffAsLongAsOneIsChosen() throws {
        #expect(ProviderChoiceModel.surfacesProvider(notesEnabled: false, isLocal: false))
        #expect(ProviderChoiceModel.surfacesProvider(notesEnabled: true, isLocal: false))
        #expect(ProviderChoiceModel.surfacesProvider(notesEnabled: true, isLocal: true))
        #expect(!ProviderChoiceModel.surfacesProvider(notesEnabled: false, isLocal: true))
        for file in [
            "Sources/MeetingsPlugin/UI/MeetingsSettingsPane.swift",
            "Sources/MeetingsPlugin/MeetingsPlugin+Status.swift",
        ] {
            let source = try String(contentsOf: Self.root.appending(path: file), encoding: .utf8)
            #expect(source.contains("surfacesProvider("), "\(file) must decide through surfacesProvider")
        }
    }

    // MARK: B2 and B3 a running job follows the choice

    private func blockedFirstCall() -> (CountingProviderProcess, Flag) {
        let started = Flag()
        let process = CountingProviderProcess { call, _ in
            if call == 1 {
                started.set()
                // Never released: only the cancellation (SIGTERM in the real runner) ends it.
                while true { try await Task.sleep(for: .milliseconds(2)) }
            }
            return ProviderFixtures.output(answer: ProviderFixtures.draft)
        }
        return (process, started)
    }

    @Test func useLocalDuringAJobStopsTheProcessAndWritesOnTheBuiltInModelOnce() async throws {
        let (process, started) = blockedFirstCall()
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let id = try await rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await waitFor("the provider process") { started.isSet })
        rig.settings.clearNotesProvider()
        rig.service.selectionChanged()
        #expect(await rig.settle())
        #expect(process.contentRuns == 1, "no second provider process")
        #expect(!rig.llm.calls.isEmpty, "the built-in model wrote the notes once")
        let record = try rig.record(id)
        #expect(record.provider == nil, "no provider mark on notes written after the switch")
    }

    @Test func changingTheModelDuringAJobRestartsItOnTheNewModel() async throws {
        let (process, started) = blockedFirstCall()
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let id = try await rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await waitFor("the provider process") { started.isSet })
        rig.settings.setNotesProvider(NotesProviderSelection(provider: .claudeCode, model: "opus"))
        rig.service.selectionChanged()
        #expect(await rig.settle())
        let specs = process.specs
        #expect(specs.count == 2)
        #expect(specs.first?.arguments.contains("sonnet") == true)
        #expect(specs.last?.arguments.contains("opus") == true)
        #expect(rig.llm.calls.isEmpty, "no built-in fallback")
        #expect(try rig.record(id).providerModel == "opus")
    }

    @Test func aChoiceThatDidNotChangeLeavesTheRunningJobAlone() async throws {
        let release = Flag()
        let started = Flag()
        let process = CountingProviderProcess { _, _ in
            started.set()
            while !release.isSet { try await Task.sleep(for: .milliseconds(2)) }
            return ProviderFixtures.output(answer: ProviderFixtures.draft)
        }
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let id = try await rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await waitFor("the provider process") { started.isSet })
        rig.service.selectionChanged()
        release.set()
        #expect(await rig.settle())
        #expect(process.contentRuns == 1)
    }

    @Test func theMenusCallTheServiceWhenTheChoiceChanges() throws {
        let source = try String(
            contentsOf: Self.root.appending(path: "Sources/MeetingsPlugin/Notes/ProviderChoiceModel.swift"),
            encoding: .utf8)
        #expect(source.components(separatedBy: "service.selectionChanged()").count - 1 >= 2)
    }

    // MARK: M1 a model the provider does not offer starts nothing

    @Test func aHiddenModelSetOutsideTheUIStartsNoProcess() async throws {
        let process = CountingProviderProcess()
        var settings = ProviderFixtures.chosen
        settings["plugins.meetings.notesProviderModel"] = .string("haiku")
        let rig = try NotesServiceRig(settings: settings, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let id = try await rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(process.contentRuns == 0)
    }

    // MARK: M2 Erase Data forgets the choice

    @Test func eraseDataClearsTheProviderChoiceAndTheHandPickedCLI() async throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        try await plugin.activate()
        harness.meetingsSettings.setNotesProvider(NotesProviderSelection(provider: .claudeCode, model: "opus"))
        harness.meetingsSettings.setNotesProviderBinary("/opt/tools/claude")
        await plugin.deactivate()
        try await plugin.eraseData()
        #expect(harness.meetingsSettings.notesProviderSelection == nil)
        #expect(harness.meetingsSettings.notesProviderBinary == nil)
    }

    // MARK: M4 the probes are not started at every activation

    @Test func appActivationLooksAtAWorkingCLIOnlyAfterTheInterval() async throws {
        let notes = try NotesServiceRig(settings: ProviderFixtures.chosen)
        let choice = ProviderChoiceRig(settings: notes.settings, service: notes.service)
        choice.model.refreshStatus()
        #expect(await waitFor("the first check") { choice.model.status == .ready })
        choice.model.refreshStatus(force: false)
        choice.model.refreshStatus(force: false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(choice.probes.withLock { $0 } == 1)
        choice.clock.withLock { $0 = $0.addingTimeInterval(ProviderChoiceModel.probeInterval + 1) }
        choice.model.refreshStatus(force: false)
        #expect(await waitFor("the second check") { choice.probes.withLock { $0 } == 2 })
        choice.model.checkAgain()
        #expect(await waitFor("the explicit check") { choice.probes.withLock { $0 } == 3 })
    }

    @Test func aProblemIsLookedAtAgainOnEveryActivation() async throws {
        let notes = try NotesServiceRig(settings: ProviderFixtures.chosen)
        let choice = ProviderChoiceRig(settings: notes.settings, service: notes.service)
        choice.report.withLock { $0 = ProviderStatusReport(status: .notSignedIn, version: nil) }
        choice.model.refreshStatus()
        #expect(await waitFor("the first check") { choice.model.status == .notSignedIn })
        choice.model.refreshStatus(force: false)
        #expect(await waitFor("the second check") { choice.probes.withLock { $0 } == 2 })
    }

    @Test func noFallbackToTheBuiltInModelAfterAFailure() async throws {
        let process = CountingProviderProcess { _, _ in
            ProviderFixtures.output(answer: "Not logged in", isError: true)
        }
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let id = try await rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(rig.llm.calls.isEmpty)
    }

    // MARK: Mockup state 7: the mark of earlier notes stays after Use Local

    @Test func afterUseLocalTheMarkOfTheEarlierNotesIsShown() throws {
        let mark = ProviderChoiceModel.EarlierMark(
            title: "Weekly", chip: "Sent to: Claude · Sonnet", provider: "Claude Code")
        let notes = try NotesServiceRig(settings: ProviderFixtures.chosen)
        let choice = ProviderChoiceRig(settings: notes.settings, service: notes.service, lastMarked: { mark })
        choice.model.reload()
        #expect(choice.model.earlierMark == nil, "not while a provider is chosen")
        choice.model.useLocal()
        #expect(choice.model.earlierMark == mark)
    }

    // MARK: Hand-picked CLI: visible path and the way back

    @Test func theHandPickedPathIsShownAndRestoreDefaultForgetsItAndChecksAgain() async throws {
        let notes = try NotesServiceRig(settings: ProviderFixtures.chosen)
        let choice = ProviderChoiceRig(settings: notes.settings, service: notes.service)
        choice.pickedFile.withLock { $0 = URL(filePath: "/opt/tools/claude") }
        choice.model.chooseBinary()
        #expect(choice.model.manualPath == "/opt/tools/claude")
        choice.model.reload()
        #expect(choice.model.manualPath == "/opt/tools/claude", "also after a reload, e.g. a path written by defaults")
        let probes = choice.probes.withLock { $0 }
        choice.model.restoreDefaultBinary()
        #expect(choice.model.manualPath == nil)
        #expect(notes.settings.notesProviderBinary == nil)
        #expect(await waitFor("the check") { choice.probes.withLock { $0 } > probes })
    }
}
