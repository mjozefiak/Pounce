import Foundation
import LintelKit
import LintelSpeech
import Synchronization
import Testing

@testable import LintelProviders
@testable import MeetingsPlugin

/// Spec `2026-11-10-external-ai-providers`, owner decision 2026-11-20: choosing the provider in settings is the
/// consent, so the matrix is "0 processes with content while no provider is chosen". Everything runs on a fake
/// process; no real CLI starts and nothing reaches `~/.claude`.
@MainActor
@Suite struct ProviderNotesMatrixTests {
    /// Runs one ready meeting through a rig with these settings and returns the number of content processes.
    private func runs(settings: [String: SettingValue]) async throws -> (runs: Int, rig: NotesServiceRig, id: Int64) {
        let process = CountingProviderProcess()
        let rig = try NotesServiceRig(settings: settings, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let id = try await rig.addMeeting()
        rig.library.meetingReady(id)
        #expect(await rig.settle())
        return (process.contentRuns, rig, id)
    }

    @Test func theDefaultSettingStartsNoProviderProcess() async throws {
        let (count, rig, id) = try await runs(settings: ["plugins.meetings.notesEnabled": .bool(true)])
        #expect(count == 0)
        let record = try rig.record(id)
        #expect(record.provider == nil && record.providerModel == nil)
        #expect(record.model == LLMModelCatalog.defaultModel.id)
        #expect(!rig.llm.calls.isEmpty)
    }

    @Test(
        arguments: [
            (
                "an unknown provider id",
                ["notesProvider": SettingValue.string("other-cli"), "notesProviderModel": .string("sonnet")]
            ),
            ("an empty provider id", ["notesProvider": .string(""), "notesProviderModel": .string("sonnet")]),
            ("a provider without a model", ["notesProvider": .string("claude-code")]),
            ("a model without a provider", ["notesProviderModel": .string("sonnet")]),
            (
                "a malformed model id",
                ["notesProvider": .string("claude-code"), "notesProviderModel": .string("--x; rm")]
            ),
            ("an empty model id", ["notesProvider": .string("claude-code"), "notesProviderModel": .string("")]),
            ("a value of the wrong type", ["notesProvider": .integer(1), "notesProviderModel": .bool(true)]),
            ("an upper case id", ["notesProvider": .string("Claude-Code"), "notesProviderModel": .string("sonnet")]),
        ] as [(String, [String: SettingValue])])
    func aValueThatDoesNotParseIsNotAChoice(_ name: String, _ values: [String: SettingValue]) async throws {
        var settings: [String: SettingValue] = ["plugins.meetings.notesEnabled": .bool(true)]
        for (key, value) in values { settings["plugins.meetings." + key] = value }
        let (count, rig, id) = try await runs(settings: settings)
        #expect(count == 0, Comment(rawValue: name))
        #expect(try rig.record(id).provider == nil)
        #expect(!rig.llm.calls.isEmpty, "the built-in model wrote the notes")
    }

    @Test func theAppsOwnDescriptorStartsNothingBeforeTheIsolationProof() async throws {
        let process = CountingProviderProcess()
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process, verified: false))
        await rig.start()
        let id = try await rig.addMeeting()
        rig.library.meetingReady(id)
        #expect(await rig.settle())
        #expect(process.contentRuns == 0)
        #expect(process.probeRuns == 0)
        #expect(try rig.record(id).status == .failed)
        #expect(rig.llm.calls.isEmpty, "no fallback to the built-in model")
    }

    @Test func aChosenProviderWithoutARunnerEndsFailedAndStartsNothing() async throws {
        let rig = try NotesServiceRig(settings: ProviderFixtures.chosen)
        await rig.start()
        let id = try await rig.addMeeting()
        rig.library.meetingReady(id)
        #expect(await rig.settle())
        #expect(try rig.record(id).status == .failed)
        #expect(rig.llm.calls.isEmpty)
    }

    @Test func changingToTheBuiltInModelWhileJobsAreQueuedStartsNoMoreProviderProcesses() async throws {
        let first = Flag()
        let release = Flag()
        let process = CountingProviderProcess { call, _ in
            first.set()
            while !release.isSet { try await Task.sleep(for: .milliseconds(2)) }
            return ProviderFixtures.output(answer: ProviderFixtures.draft)
        }
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let one = try await rig.addMeeting()
        let two = try await rig.addMeeting()
        let three = try await rig.addMeeting()
        rig.service.meetingBecameReady(one)
        rig.service.meetingBecameReady(two)
        rig.service.meetingBecameReady(three)
        #expect(await rig.wait("the first provider process") { first.isSet })
        // The user switches back to the built-in model: the queued jobs are not sent.
        rig.settings.clearNotesProvider()
        release.set()
        #expect(await rig.settle())
        #expect(process.contentRuns == 1)
        #expect(try rig.record(one).provider == "claude-code")
        for id in [two, three] {
            let record = try rig.record(id)
            #expect(record.provider == nil && record.providerModel == nil)
            #expect(record.model == LLMModelCatalog.defaultModel.id)
        }
    }

    @Test func aRetryAfterTheChoiceWasRemovedGetsNoProcessAndKeepsTheEarlierNotes() async throws {
        let holder = Mutex<MeetingsSettings?>(nil)
        // The first answer is unusable, so the track would retry; the user is back on the built-in model by then.
        let process = CountingProviderProcess { _, _ in
            holder.withLock { $0 }?.clearNotesProvider()
            return ProviderFixtures.output(answer: "no format at all")
        }
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        holder.withLock { $0 = rig.settings }
        await rig.start()
        let id = try await rig.addMeeting()
        try await rig.perform {
            _ = try $0.beginNotes(id)
            try $0.finishNotes(
                id, markdown: "Earlier notes", status: .ok, promptVersion: "1", model: "m", droppedCount: 0,
                generatedAt: Date(timeIntervalSince1970: 1))
        }
        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(process.contentRuns == 1)
        let record = try rig.record(id)
        #expect(record.status == .ok, "the earlier status is back, nothing partial")
        #expect(try rig.document(id).notesMarkdown == "Earlier notes")
        #expect(record.provider == nil && record.model == "m")
        #expect(rig.llm.calls.isEmpty, "no second job on the built-in model")
    }

    @Test func aTranscriptOverEightPartsStartsNothing() async throws {
        let process = CountingProviderProcess()
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let long = (0..<10).map { index in
            NotesUtterance(
                startMs: index * 60_000, speaker: index.isMultiple(of: 2) ? "Anna" : "Marek",
                text: String(repeating: "omawiamy budżet projektu ", count: 6_000))
        }
        let id = try await rig.addMeeting(long)
        rig.library.meetingReady(id)
        #expect(await rig.settle())
        #expect(process.contentRuns == 0)
        #expect(try rig.record(id).status == .failed)
        #expect(rig.llm.calls.isEmpty)
    }
}

@MainActor
@Suite struct ProviderNotesGeneratorTests {
    @Test func theChosenProviderWritesTheNotesAndTheOriginIsRecorded() async throws {
        let process = CountingProviderProcess()
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let id = try await rig.addMeeting()
        rig.library.meetingReady(id)
        #expect(await rig.settle())

        #expect(process.contentRuns == 1)
        let record = try rig.record(id)
        #expect(record.status == .ok)
        #expect(record.provider == "claude-code")
        #expect(record.providerModel == "sonnet")
        #expect(record.model == nil, "notes_model is NULL for a provider")
        #expect(record.promptVersion == "whole1+cli1")
        let notes = try #require(try rig.document(id).notesMarkdown)
        #expect(notes.contains("Budżet marketingowy"))
        #expect(rig.llm.calls.isEmpty, "the built-in model was not used")
        #expect(rig.service.board.snapshot.phases.isEmpty)
        #expect(!rig.service.board.snapshot.modelMissing, "a chosen provider needs no built-in model")
    }

    @Test func theRequestCarriesTheIsolationFlagsTheTranscriptOnStdinOnlyAndTheTimeout() async throws {
        let process = CountingProviderProcess()
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let id = try await rig.addMeeting()
        rig.library.meetingReady(id)
        #expect(await rig.settle())

        let spec = try #require(process.specs.first)
        for flag in ["--safe-mode", "--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands"] {
            #expect(spec.arguments.contains(flag), Comment(rawValue: flag))
        }
        let tools = try #require(spec.arguments.firstIndex(of: "--tools"))
        #expect(spec.arguments[tools + 1].isEmpty)
        let sources = try #require(spec.arguments.firstIndex(of: "--setting-sources"))
        #expect(spec.arguments[sources + 1].isEmpty)
        #expect(spec.arguments.contains("sonnet"))
        #expect(spec.timeout == .seconds(600))

        // The transcript, the speaker names and the times go on stdin; none of it is in argv.
        let stdin = String(decoding: spec.stdin, as: UTF8.self)
        for utterance in NotesFixtures.meeting() {
            #expect(stdin.contains(utterance.text))
            #expect(stdin.contains(utterance.speaker))
        }
        #expect(stdin.contains("[00:05]"))
        let argv = spec.arguments.joined(separator: "\n")
        for utterance in NotesFixtures.meeting() { #expect(!argv.contains(utterance.text)) }
        // Nothing else of the user's: the environment is the allowlist and the folder is new and empty.
        #expect(Set(spec.environment.keys).isSubset(of: Set(ProviderDescriptor.claudeEnvironmentAllowlist + ["PATH"])))
    }

    @Test func aFailedProviderRunRetriesOnceThenFailsWithoutTheBuiltInModel() async throws {
        let process = CountingProviderProcess { _, _ in ProviderFixtures.output(answer: "rate limit", isError: true) }
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let id = try await rig.addMeeting()
        try await rig.perform {
            _ = try $0.beginNotes(id)
            try $0.finishNotes(
                id, markdown: "Earlier notes", status: .ok, promptVersion: "1", model: "m", droppedCount: 0,
                generatedAt: Date(timeIntervalSince1970: 1))
        }
        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(process.contentRuns == 2)
        #expect(try rig.record(id).status == .failed)
        #expect(try rig.document(id).notesMarkdown == "Earlier notes")
        #expect(rig.llm.calls.isEmpty)
    }

    @Test func shuttingDownCancelsTheRunningProcessAndStartsNoMore() async throws {
        let started = Flag()
        let process = CountingProviderProcess { _, _ in
            started.set()
            try await Task.sleep(for: .seconds(3600))  // ends only by cancellation, like the real process does
            return ProviderFixtures.output(answer: ProviderFixtures.draft)
        }
        let rig = try NotesServiceRig(
            settings: ProviderFixtures.chosen, providerRunner: ProviderFixtures.runner(process))
        await rig.start()
        let id = try await rig.addMeeting()
        rig.service.meetingBecameReady(id)
        #expect(await rig.wait("the process to start") { started.isSet })
        await rig.service.shutDown()
        #expect(process.contentRuns == 1)
        #expect(try rig.record(id).status != .running)
        // Starting again by itself sends nothing.
        await rig.start()
        #expect(process.contentRuns == 1)
    }

    @Test func theInputBudgetIsPerModel() {
        #expect(ProviderDescriptor.claudeCode.inputBudgetTokens(forModel: "sonnet") == 100_000)
        #expect(ProviderDescriptor.claudeCode.inputBudgetTokens(forModel: "some-new-model") == 100_000)
        let small = ProviderModel(id: "tiny", displayName: "Tiny", inputBudgetTokens: 1_000)
        #expect(small.inputBudgetTokens == 1_000)
    }

    @Test func theSettingsReadTheChoiceFreshAndDefaultToTheBuiltInModel() throws {
        let harness = try MeetingsHarness(settings: [:])
        let settings = harness.meetingsSettings
        #expect(settings.notesProviderSelection == nil)
        settings.setNotesProvider(NotesProviderSelection(provider: .claudeCode, model: "haiku"))
        #expect(settings.notesProviderSelection == NotesProviderSelection(provider: .claudeCode, model: "haiku"))
        settings.setNotesProvider(NotesProviderSelection(provider: .claudeCode, model: "sonnet"))
        #expect(settings.notesProviderSelection?.model == "sonnet", "a model change needs no question")
        settings.clearNotesProvider()
        #expect(settings.notesProviderSelection == nil)
    }
}
