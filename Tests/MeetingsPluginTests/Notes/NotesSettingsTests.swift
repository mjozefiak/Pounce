import Foundation
import LintelKit
import LintelSpeech
import Testing

@testable import MeetingsPlugin

/// The notes section of the settings, over a temporary `Models/llm` folder. A model counts as installed when
/// its file has the catalog's size, so the tests make sparse files of that size (they take no disk space).
@MainActor
struct NotesSettingsRig {
    let service: NotesServiceRig
    let directory: TemporaryDirectory
    let manager: ModelManager
    let model: NotesSettingsModel
    let downloader: InstantDownloader

    var settings: MeetingsSettings { service.settings }

    init(
        settings: [String: SettingValue] = [:], physicalMemory: UInt64 = 16 * NotesServiceRig.gibibyte,
        handler: @escaping ScriptedLLM.Handler = NotesFake.standard
    ) throws {
        service = try NotesServiceRig(settings: settings, physicalMemory: physicalMemory, handler: handler)
        directory = try TemporaryDirectory()
        downloader = InstantDownloader(data: ["Qwen3-4B-Instruct-2507-Q4_K_M.gguf": Data("not the model".utf8)])
        manager = ModelManager(
            directory: directory.url.appending(path: "llm", directoryHint: .isDirectory), downloader: downloader,
            availableSpace: { _ in .max })
        model = NotesSettingsModel(
            settings: service.settings, service: service.service, manager: manager, lease: service.lease)
    }

    func installedFile(of llm: LLMModel) -> URL? {
        llm.fileURL(in: directory.url.appending(path: "llm/\(llm.package.id)", directoryHint: .isDirectory))
    }

    /// Puts a file of the right size where the manager looks for `llm`.
    @discardableResult
    func install(_ llm: LLMModel) throws -> URL {
        let file = try #require(installedFile(of: llm))
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(llm.package.totalBytes))
        try handle.close()
        return file
    }
}

@MainActor
@Suite struct NotesSettingsTests {
    @Test func theSwitchIsOffAndWrittenOnlyWhenTheUserFlipsIt() async throws {
        let rig = try NotesSettingsRig()
        await rig.model.refresh()
        #expect(!rig.model.enabled)
        #expect(rig.service.harness.settings.value(forKey: "plugins.meetings.notesEnabled") == nil)
        #expect(rig.service.harness.settings.value(forKey: "plugins.meetings.builtInLLMModel") == nil)

        rig.model.enabled = true
        #expect(rig.service.harness.settings.value(forKey: "plugins.meetings.notesEnabled") == .bool(true))
        #expect(await waitFor { rig.service.service.board.snapshot.enabled })
        rig.model.enabled = false
        #expect(rig.service.harness.settings.value(forKey: "plugins.meetings.notesEnabled") == .bool(false))
    }

    @Test func theCardOffersTheModelsThatFitThisMac() async throws {
        let small = try NotesSettingsRig(physicalMemory: 16 * NotesServiceRig.gibibyte)
        #expect(small.model.models.map(\.id) == [LLMModelCatalog.qwen3Small.id])
        let big = try NotesSettingsRig(physicalMemory: 64 * NotesServiceRig.gibibyte)
        #expect(big.model.models.map(\.id) == LLMModelCatalog.all.map(\.id))
        let tiny = try NotesSettingsRig(physicalMemory: 4 * NotesServiceRig.gibibyte)
        #expect(tiny.model.models.map(\.id) == [LLMModelCatalog.defaultModel.id])
    }

    @Test func choosingAModelStoresItAndAnUnknownOneChangesNothing() async throws {
        let rig = try NotesSettingsRig(physicalMemory: 64 * NotesServiceRig.gibibyte)
        await rig.model.choose(LLMModelCatalog.qwen3Large.id)
        #expect(rig.model.model.id == LLMModelCatalog.qwen3Large.id)
        #expect(
            rig.service.harness.settings.value(forKey: "plugins.meetings.builtInLLMModel")
                == .string(LLMModelCatalog.qwen3Large.id))
        await rig.model.choose("nonsense")
        #expect(rig.model.model.id == LLMModelCatalog.qwen3Large.id)
    }

    @Test func aStoredModelThatDoesNotFitIsReportedAndReplaced() async throws {
        let rig = try NotesSettingsRig(
            settings: ["plugins.meetings.builtInLLMModel": .string(LLMModelCatalog.qwen3Large.id)])
        #expect(rig.model.wasReplaced)
        #expect(rig.model.model.id == LLMModelCatalog.defaultModel.id)
        // The stored value is not rewritten behind the user's back.
        #expect(
            rig.service.harness.settings.value(forKey: "plugins.meetings.builtInLLMModel")
                == .string(LLMModelCatalog.qwen3Large.id))
    }

    @Test func theCardSeesADownloadedModelAndRemovesIt() async throws {
        let rig = try NotesSettingsRig()
        await rig.model.refresh()
        #expect(!rig.model.isInstalled)
        let file = try rig.install(LLMModelCatalog.defaultModel)
        await rig.model.refresh()
        #expect(rig.model.isInstalled)
        #expect(!rig.model.isInUse)

        await rig.model.remove()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!rig.model.isInstalled)
        #expect(rig.model.errorMessage == nil)
    }

    @Test func theModelCannotBeRemovedWhileNotesAreBeingWritten() async throws {
        let started = Flag()
        let rig = try NotesSettingsRig(handler: { _, _, _ in
            started.set()
            try await Task.sleep(for: .seconds(3600))
            return .done("NONE")
        })
        let file = try rig.install(LLMModelCatalog.defaultModel)
        await rig.service.start()
        let id = try rig.service.addMeeting()
        rig.service.service.regenerate(id)
        #expect(await waitFor { started.isSet })
        await rig.model.refresh()
        #expect(rig.model.isInUse)

        await rig.model.remove()
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(rig.model.errorMessage == NotesMessages.modelInUse)

        await rig.service.service.shutDown()
        await rig.model.refresh()
        #expect(!rig.model.isInUse)
        await rig.model.remove()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aDownloadThatFailsTheChecksShowsAMessageAndLeavesNothing() async throws {
        let rig = try NotesSettingsRig()
        await rig.model.refresh()
        rig.model.download()
        #expect(rig.model.isDownloading)
        await rig.model.waitForDownload()
        #expect(!rig.model.isDownloading)
        #expect(rig.model.errorMessage != nil)
        #expect(!rig.model.isInstalled)
    }
}
