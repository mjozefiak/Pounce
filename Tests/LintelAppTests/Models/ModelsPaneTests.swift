import Foundation
import LintelKit
import LintelSpeech
import SwiftUI
import Testing

@testable import LintelApp

/// A model inventory in memory: no file is touched and `ModelManagers.shared` is never reached.
@MainActor
final class FakeInventory: ModelInventory {
    nonisolated let catalog: [CatalogModel]
    var states: [String: InventoryState] = [:]
    /// Package ids a shared lease holds.
    var leased: Set<String> = []
    var failInstall: (any Error)?
    /// Every call, in order: "evict:speech", "delete:a", "verify:a".
    private(set) var log: [String] = []
    /// Runs inside `delete`, before `isInUse` is asked (a recording trying to start meanwhile).
    var duringDelete: () -> Void = {}

    nonisolated init(_ catalog: [CatalogModel]) {
        self.catalog = catalog
    }

    /// Runs after a state was read and before it is returned (a slow disk overtaken by a newer refresh).
    var afterStateRead: (String) async -> Void = { _ in }

    func state(of id: String) async -> InventoryState {
        let value = states[id] ?? .missing
        await afterStateRead(id)
        return value
    }

    func install(_ id: String, progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        log.append("install:\(id)")
        progress(ModelProgress(bytesDone: 50, bytesTotal: 100))
        if let failInstall { throw failInstall }
        states[id] = .installed
    }

    func verify(folder: URL, for id: String) async throws {
        log.append("verify:\(id)")
    }

    func delete(_ id: String, unless isInUse: @escaping @Sendable () async -> Bool) async throws -> Bool {
        log.append("delete:\(id)")
        duringDelete()
        if await isInUse() { return false }
        states[id] = .missing
        return true
    }

    func isLeased(_ id: String) async -> Bool { leased.contains(id) }

    func evictIdle(_ kind: ModelKind) async {
        log.append("evict:\(kind.rawValue)")
    }
}

/// A mutable value a `@Sendable` closure can change on the main actor.
@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// A fake meeting recorder: its usages are in use while a recording runs, and its removal reservation refuses a
/// new recording (as `MeetingActivity` does).
@MainActor
final class FakeRecorder {
    var isRecording = false
    var reservations = 0
    var log: [String] = []

    /// A start while a removal is reserved is refused.
    @discardableResult
    func startRecording() -> Bool {
        guard reservations == 0 else { return false }
        isRecording = true
        return true
    }

    func usage(_ id: String, kind: ModelKind = .speech, required: Bool = true, selected: Bool = true) -> ModelUsage {
        ModelUsage(
            packageID: id, kind: kind, role: "Transcripts", isRequired: required, isSelected: selected,
            isInUse: { [unowned self] in self.isRecording },
            reserveRemoval: { [unowned self] in
                self.reservations += 1
                self.log.append("reserve")
                return { [unowned self] in
                    self.reservations -= 1
                    self.log.append("release")
                }
            })
    }
}

@MainActor
@Suite struct ModelsPaneTests {
    static let speechA = CatalogModel(id: "speech-a", title: "Speech A", kind: .speech, bytes: 100)
    static let speechB = CatalogModel(id: "speech-b", title: "Speech B", kind: .speech, bytes: 200)
    static let llm = CatalogModel(id: "llm", title: "LLM", kind: .llm, bytes: 300)
    static let diarization = CatalogModel(id: "diarization", title: "Speakers", kind: .diarization, bytes: 400)

    private func inventory() -> FakeInventory {
        FakeInventory([Self.speechA, Self.speechB, Self.llm, Self.diarization])
    }

    private func plugin(
        _ id: String, enabled: Bool = true, _ usages: [ModelUsage]
    ) -> ModelsPaneModel.PluginUsages {
        ModelsPaneModel.PluginUsages(
            pluginID: id, pluginName: id.capitalized, isEnabled: enabled, usages: usages)
    }

    // MARK: Install, progress, remove

    @Test func downloadShowsProgressAndEndsInstalled() async {
        let inventory = inventory()
        let model = ModelsPaneModel(inventory: inventory, usages: { [] })
        await model.refresh()
        model.download(Self.speechA.id)
        #expect(model.rows.first { $0.id == Self.speechA.id }?.isDownloading == true)
        await model.waitForDownload(Self.speechA.id)
        let row = model.rows.first { $0.id == Self.speechA.id }
        #expect(row?.isInstalled == true)
        #expect(row?.isDownloading == false)
        #expect(inventory.log == ["install:speech-a"])
    }

    @Test func aFailedDownloadShowsTheErrorAndCanBeTriedAgain() async {
        let inventory = inventory()
        inventory.failInstall = ModelError.httpStatus(500)
        let model = ModelsPaneModel(inventory: inventory, usages: { [] })
        model.download(Self.llm.id)
        await model.waitForDownload(Self.llm.id)
        let row = model.rows.first { $0.id == Self.llm.id }
        #expect(row?.errorMessage != nil)
        #expect(row?.isInstalled == false)
        inventory.failInstall = nil
        model.download(Self.llm.id)
        await model.waitForDownload(Self.llm.id)
        #expect(model.rows.first { $0.id == Self.llm.id }?.isInstalled == true)
        #expect(model.rows.first { $0.id == Self.llm.id }?.errorMessage == nil)
    }

    @Test func aModelTooBigForThisMacIsNotOfferedForDownload() async {
        let big = CatalogModel(id: "big", title: "Big", kind: .llm, bytes: 1, canDownload: false)
        let inventory = FakeInventory([big])
        let model = ModelsPaneModel(inventory: inventory, usages: { [] })
        model.download("big")
        await model.waitForDownload("big")
        #expect(inventory.log.isEmpty)
    }

    @Test func removeDeletesAnIdleModel() async {
        let inventory = inventory()
        inventory.states[Self.speechA.id] = .installed
        let model = ModelsPaneModel(inventory: inventory, usages: { [] })
        await model.refresh()
        await model.remove(Self.speechA.id)
        #expect(model.rows.first { $0.id == Self.speechA.id }?.isInstalled == false)
        #expect(inventory.log == ["evict:speech", "delete:speech-a"])
    }

    @Test func aUsageInUseRefusesRemoval() async {
        let inventory = inventory()
        inventory.states[Self.llm.id] = .installed
        let usage = ModelUsage(
            packageID: Self.llm.id, kind: .llm, role: "Notes", isRequired: false, isSelected: true,
            isInUse: { true })
        let model = ModelsPaneModel(inventory: inventory, usages: { [self.plugin("meetings", [usage])] })
        await model.refresh()
        await model.remove(Self.llm.id)
        let row = model.rows.first { $0.id == Self.llm.id }
        #expect(row?.isInstalled == true)
        #expect(row?.errorMessage == ModelsPaneModel.inUseMessage)
        #expect(!inventory.log.contains("delete:llm"))
    }

    @Test func aSharedLeaseRefusesRemoval() async {
        let inventory = inventory()
        inventory.states[Self.speechA.id] = .installed
        inventory.leased = [Self.speechA.id]
        let model = ModelsPaneModel(inventory: inventory, usages: { [] })
        await model.refresh()
        await model.remove(Self.speechA.id)
        #expect(model.rows.first { $0.id == Self.speechA.id }?.isInstalled == true)
        #expect(model.rows.first { $0.id == Self.speechA.id }?.errorMessage == ModelsPaneModel.inUseMessage)
    }

    /// Meetings selects model B and records with it; removing A (the same kind, not listed) and removing B are
    /// both refused, since the plugin can switch models while a run on the old one continues.
    @Test func aRecordingOnModelBRefusesRemovingModelAAndModelB() async {
        let inventory = inventory()
        inventory.states = [Self.speechA.id: .installed, Self.speechB.id: .installed]
        let recorder = FakeRecorder()
        let usages = [plugin("meetings", [recorder.usage(Self.speechB.id)])]
        let model = ModelsPaneModel(inventory: inventory, usages: { usages })
        await model.refresh()
        recorder.startRecording()
        await model.remove(Self.speechA.id)
        await model.remove(Self.speechB.id)
        #expect(model.rows.filter(\.isInstalled).map(\.id) == [Self.speechA.id, Self.speechB.id])
        #expect(!inventory.log.contains { $0.hasPrefix("delete:") })
        recorder.isRecording = false
        await model.remove(Self.speechA.id)
        #expect(model.rows.filter(\.isInstalled).map(\.id) == [Self.speechB.id])
    }

    @Test func removingTheDiarizationModelDuringAMeetingIsRefused() async {
        let inventory = inventory()
        inventory.states[Self.diarization.id] = .installed
        let recorder = FakeRecorder()
        let usages = [
            plugin(
                "meetings",
                [
                    recorder.usage(Self.speechA.id),
                    recorder.usage(Self.diarization.id, kind: .diarization, required: false),
                ])
        ]
        let model = ModelsPaneModel(inventory: inventory, usages: { usages })
        await model.refresh()
        recorder.startRecording()
        await model.remove(Self.diarization.id)
        #expect(model.rows.first { $0.id == Self.diarization.id }?.isInstalled == true)
        #expect(model.rows.first { $0.id == Self.diarization.id }?.errorMessage == ModelsPaneModel.inUseMessage)
    }

    @Test func aUsageOfAnotherKindDoesNotGuardRemoval() async {
        let inventory = inventory()
        inventory.states[Self.speechA.id] = .installed
        let busyLLM = ModelUsage(
            packageID: Self.llm.id, kind: .llm, role: "Notes", isRequired: false, isSelected: true,
            isInUse: { true })
        let model = ModelsPaneModel(inventory: inventory, usages: { [self.plugin("meetings", [busyLLM])] })
        await model.refresh()
        await model.remove(Self.speechA.id)
        #expect(model.rows.first { $0.id == Self.speechA.id }?.isInstalled == false)
    }

    @Test func aDisabledPluginsUsageStillGuardsRemoval() async {
        let inventory = inventory()
        inventory.states[Self.speechA.id] = .installed
        let recorder = FakeRecorder()
        recorder.isRecording = true
        let usages = [plugin("meetings", enabled: false, [recorder.usage(Self.speechA.id)])]
        let model = ModelsPaneModel(inventory: inventory, usages: { usages })
        await model.refresh()
        await model.remove(Self.speechA.id)
        #expect(model.rows.first { $0.id == Self.speechA.id }?.isInstalled == true)
    }

    // MARK: Confirmation

    @Test func removeAsksFirstAndCancellingDeletesNothing() async throws {
        let inventory = inventory()
        inventory.states[Self.speechA.id] = .installed
        let model = ModelsPaneModel(inventory: inventory, usages: { [] })
        await model.refresh()
        model.requestRemoval(Self.speechA.id)
        #expect(model.pendingRemoval == Self.speechA.id)
        #expect(inventory.log.isEmpty)
        model.cancelRemoval()
        #expect(model.pendingRemoval == nil)
        #expect(model.confirmRemoval() == nil)
        #expect(inventory.log.isEmpty)
        #expect(model.rows.first { $0.id == Self.speechA.id }?.isInstalled == true)

        model.requestRemoval(Self.speechA.id)
        await try #require(model.confirmRemoval()).value
        #expect(inventory.log == ["evict:speech", "delete:speech-a"])
        #expect(model.rows.first { $0.id == Self.speechA.id }?.isInstalled == false)
    }

    @Test func theRemovalConfirmationNamesTheModelAndSaysRemoveModel() {
        let model = ModelsPaneModel(inventory: inventory(), usages: { [] })
        model.requestRemoval(Self.speechB.id)
        let confirmation = model.removalConfirmation
        #expect(String(localized: confirmation.prompt) == "Remove Speech B?")
        #expect(String(localized: confirmation.confirmTitle) == "Remove Model")
        #expect(String(localized: confirmation.detail).contains("downloaded again"))
    }

    /// The Remove button only asks; the delete runs from the `ConfirmSheet`, whose default button is Cancel.
    @Test func theRemoveButtonGoesThroughTheConfirmSheet() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/LintelApp/Settings/Models/ModelsPane.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("remove: { model.requestRemoval(row.id) }"))
        #expect(!source.contains("model.remove("))
        #expect(source.contains(".destructiveConfirmation("))
    }

    // MARK: Reservation and eviction

    @Test func theReservationIsTakenBeforeTheFirstInUseCheck() async {
        let inventory = inventory()
        inventory.states[Self.speechA.id] = .installed
        let recorder = FakeRecorder()
        recorder.isRecording = true
        let usages = [plugin("meetings", [recorder.usage(Self.speechA.id)])]
        let model = ModelsPaneModel(inventory: inventory, usages: { usages })
        await model.refresh()
        await model.remove(Self.speechA.id)
        // Refused, and the reservation was held for the check and released after it.
        #expect(recorder.log == ["reserve", "release"])
        #expect(!inventory.log.contains { $0.hasPrefix("delete:") })
    }

    @Test func theReservationIsHeldDuringRemovalAndBlocksStartingARecording() async {
        let inventory = inventory()
        inventory.states[Self.speechA.id] = .installed
        let meetings = FakeRecorder()
        let dictation = FakeRecorder()
        // Dictation is off and lists another speech model: its reservation is held too.
        let usages = [
            plugin("meetings", [meetings.usage(Self.speechA.id)]),
            plugin("dictation", enabled: false, [dictation.usage(Self.speechB.id)]),
        ]
        var startedDuringDelete: Bool?
        inventory.duringDelete = {
            #expect(meetings.reservations == 1)
            #expect(dictation.reservations == 1)
            startedDuringDelete = meetings.startRecording()
        }
        let model = ModelsPaneModel(inventory: inventory, usages: { usages })
        await model.refresh()
        await model.remove(Self.speechA.id)
        #expect(startedDuringDelete == false)
        #expect(meetings.reservations == 0)
        #expect(dictation.reservations == 0)
        #expect(model.rows.first { $0.id == Self.speechA.id }?.isInstalled == false)
        #expect(meetings.startRecording())
    }

    @Test func anIdleWarmModelIsEvictedInsideTheReservationAndBeforeTheDelete() async {
        let inventory = inventory()
        inventory.states[Self.llm.id] = .installed
        let recorder = FakeRecorder()
        let usages = [plugin("dictation", [recorder.usage(Self.llm.id, kind: .llm, required: false)])]
        let model = ModelsPaneModel(inventory: inventory, usages: { usages })
        await model.refresh()
        var order: [String] = []
        inventory.duringDelete = { order = recorder.log + inventory.log }
        await model.remove(Self.llm.id)
        #expect(order == ["reserve", "evict:llm", "delete:llm"])
        #expect(recorder.log == ["reserve", "release"])
    }

    // MARK: Used by, needed, banner

    @Test func withSpeechInstalledAndDiarizationMissingThereIsNoNeededBanner() async {
        let inventory = inventory()
        inventory.states[Self.speechA.id] = .installed
        let usages = [
            plugin(
                "meetings",
                [
                    ModelUsage(
                        packageID: Self.speechA.id, kind: .speech, role: "Transcripts", isRequired: true,
                        isSelected: true),
                    ModelUsage(
                        packageID: Self.diarization.id, kind: .diarization, role: "Speakers", isRequired: false,
                        isSelected: true),
                ])
        ]
        let model = ModelsPaneModel(inventory: inventory, usages: { usages })
        await model.refresh()
        #expect(model.banner == nil)
        let row = model.rows.first { $0.id == Self.diarization.id }
        #expect(row?.usedBy.map(\.label) == ["Meetings"])
        #expect(row?.usedByText?.contains("Meetings") == true)
        #expect(row?.isNeeded == false)
    }

    @Test func withMeetingsOnAndNothingInstalledOneModelIsNeeded() async {
        let usages = [
            plugin(
                "meetings",
                [
                    ModelUsage(
                        packageID: Self.speechA.id, kind: .speech, role: "Transcripts", isRequired: true,
                        isSelected: true),
                    ModelUsage(
                        packageID: Self.diarization.id, kind: .diarization, role: "Speakers", isRequired: false,
                        isSelected: true),
                    ModelUsage(packageID: Self.llm.id, kind: .llm, role: "Notes", isRequired: false, isSelected: false),
                ]),
            plugin(
                "dictation", enabled: false,
                [
                    ModelUsage(
                        packageID: Self.speechB.id, kind: .speech, role: "Dictation", isRequired: true, isSelected: true
                    )
                ]),
        ]
        let model = ModelsPaneModel(inventory: inventory(), usages: { usages })
        await model.refresh()
        #expect(model.neededIDs == [Self.speechA.id])
        #expect(model.banner?.level == .attention)
        #expect(model.banner?.title.contains("1") == true)
        #expect(model.rows.first { $0.id == Self.speechA.id }?.isNeeded == true)
        // A disabled plugin's usage is shown as off and never makes a model needed.
        let off = model.rows.first { $0.id == Self.speechB.id }
        #expect(off?.isNeeded == false)
        #expect(off?.usedBy.first?.isEnabled == false)
        #expect(off?.usedBy.first?.label.contains("Dictation") == true)
        // An unselected usage is no chip.
        #expect(model.rows.first { $0.id == Self.llm.id }?.usedBy.isEmpty == true)
    }

    @Test func noModelIsNeededBeforeTheFirstRefresh() async {
        let usage = ModelUsage(packageID: Self.speechA.id, kind: .speech, role: "x", isRequired: true, isSelected: true)
        let model = ModelsPaneModel(inventory: inventory(), usages: { [self.plugin("meetings", [usage])] })
        #expect(!model.hasLoaded)
        #expect(model.banner == nil)
        #expect(model.rows.allSatisfy { !$0.isNeeded })
        await model.refresh()
        #expect(model.hasLoaded)
        #expect(model.banner != nil)
    }

    @Test func anOvertakenRefreshDoesNotWriteStaleStates() async {
        let inventory = inventory()
        let firstPaused = Box(false)
        let gate = Box<CheckedContinuation<Void, Never>?>(nil)
        inventory.afterStateRead = { id in
            guard id == Self.speechA.id, !firstPaused.value else { return }
            firstPaused.value = true
            await withCheckedContinuation { gate.value = $0 }
        }
        let model = ModelsPaneModel(inventory: inventory, usages: { [] })
        // The first refresh reads "missing" and stalls; meanwhile the model is installed and a second one runs.
        let first = Task { await model.refresh() }
        for _ in 0..<1_000 where gate.value == nil { await Task.yield() }
        inventory.states[Self.speechA.id] = .installed
        await model.refresh()
        #expect(model.rows.first { $0.id == Self.speechA.id }?.isInstalled == true)
        gate.value?.resume()
        await first.value
        #expect(model.rows.first { $0.id == Self.speechA.id }?.isInstalled == true)
    }

    /// A model in a folder the user chose is not seen by the inventory, so the plugins declare it not required
    /// then (`ModelUsage.isRequired` is `speechModelFolder == nil`): no banner and no second download.
    @Test func aCustomFolderGivesNoNeededBanner() async {
        let chosenFolder = ModelUsage(
            packageID: Self.speechA.id, kind: .speech, role: "x", isRequired: false, isSelected: true)
        let model = ModelsPaneModel(inventory: inventory(), usages: { [self.plugin("dictation", [chosenFolder])] })
        await model.refresh()
        #expect(model.banner == nil)
        #expect(model.rows.first { $0.id == Self.speechA.id }?.isNeeded == false)
    }

    @Test func twoPluginsNeedingTheSameModelCountOnce() async {
        let usage = ModelUsage(packageID: Self.speechA.id, kind: .speech, role: "x", isRequired: true, isSelected: true)
        let usages = [plugin("meetings", [usage]), plugin("dictation", [usage])]
        let model = ModelsPaneModel(inventory: inventory(), usages: { usages })
        await model.refresh()
        #expect(model.neededIDs.count == 1)
    }

    @Test func withBothVoicePluginsOffNothingIsNeeded() async {
        let usage = ModelUsage(packageID: Self.speechA.id, kind: .speech, role: "x", isRequired: true, isSelected: true)
        let usages = [plugin("meetings", enabled: false, [usage]), plugin("dictation", enabled: false, [usage])]
        let model = ModelsPaneModel(inventory: inventory(), usages: { usages })
        await model.refresh()
        #expect(model.banner == nil)
        #expect(model.neededIDs.isEmpty)
    }

    @Test func anUnknownPackageIsIgnored() async {
        let usage = ModelUsage(packageID: "nope", kind: .speech, role: "x", isRequired: true, isSelected: true)
        let model = ModelsPaneModel(inventory: inventory(), usages: { [self.plugin("meetings", [usage])] })
        await model.refresh()
        #expect(model.banner == nil)
        #expect(model.rows.count == 4)
    }

    @Test func rowsAreGroupedByKind() {
        let model = ModelsPaneModel(inventory: inventory(), usages: { [] })
        #expect(model.kinds == [.speech, .llm, .diarization])
        #expect(model.rows(of: .speech).map(\.id) == [Self.speechA.id, Self.speechB.id])
    }

    // MARK: Prototype fidelity (set-models)

    @Test func speechAndSpeakerModelsShareOneCardAndLanguageModelsAreWriting() {
        let model = ModelsPaneModel(inventory: inventory(), usages: { [] })
        #expect(model.sections.map(\.id) == ["speech", "writing"])
        #expect(model.sections.map(\.title) == ["Speech", "Writing"])
        #expect(
            model.rows(in: model.sections[0]).map(\.id) == [Self.speechA.id, Self.speechB.id, Self.diarization.id])
        #expect(model.rows(in: model.sections[1]).map(\.id) == [Self.llm.id])
    }

    @Test func theSpeakerModelIsCalledSpeakerSeparation() {
        let model = ModelsPaneModel(inventory: inventory(), usages: { [] })
        #expect(model.rows.first { $0.id == Self.diarization.id }?.title == "Speaker separation")
        #expect(model.rows.first { $0.id == Self.speechA.id }?.title == "Speech A")
    }

    @Test func aMissingModelReadsNotDownloaded() async {
        let model = ModelsPaneModel(inventory: inventory(), usages: { [] })
        await model.refresh()
        #expect(model.rows.first { $0.id == Self.speechA.id }?.stateText == "Not downloaded")
    }

    @Test func theLicenceComesFromTheCatalogOrIsOmitted() {
        let licensed = CatalogModel(id: "a", title: "A", kind: .speech, bytes: 1, license: "MIT")
        let plain = CatalogModel(id: "b", title: "B", kind: .speech, bytes: 1)
        #expect(licensed.license == "MIT")
        #expect(plain.license == nil)
        let real = SharedModelInventory(modelsDirectory: URL(filePath: "/nonexistent"), physicalMemory: 64 << 30)
        #expect(real.catalog.allSatisfy { $0.license?.isEmpty == false })
        #expect(real.catalog.first { $0.id == LLMModelCatalog.defaultModel.id }?.license == "Apache-2.0")
    }

    @Test func theWritingFooterUsesTheCatalogMemoryFigureOnly() {
        let withFigure = CatalogModel(id: "llm", title: "LLM", kind: .llm, bytes: 1, residentBytes: 3_274_784_768)
        let model = ModelsPaneModel(inventory: FakeInventory([withFigure]), usages: { [] })
        let footer = model.writingMemoryFooter
        #expect(footer?.hasPrefix("Needs about ") == true)
        #expect(footer?.hasSuffix(" of memory while writing.") == true)
        #expect(footer?.contains("3") == true)
        let unknown = ModelsPaneModel(inventory: inventory(), usages: { [] })
        #expect(unknown.writingMemoryFooter == nil)
    }

    @Test func theNeededModelsDownloadIsThePrimaryAction() async {
        let usage = ModelUsage(packageID: Self.speechA.id, kind: .speech, role: "x", isRequired: true, isSelected: true)
        let model = ModelsPaneModel(inventory: inventory(), usages: { [self.plugin("meetings", [usage])] })
        await model.refresh()
        #expect(model.rows.first { $0.id == Self.speechA.id }?.isPrimaryAction == true)
        #expect(model.rows.first { $0.id == Self.speechB.id }?.isPrimaryAction == false)
    }

    @Test func theBannerOffersDownloadingTheNeededModelAndItStartsTheDownload() async throws {
        let inventory = inventory()
        let usage = ModelUsage(packageID: Self.speechA.id, kind: .speech, role: "x", isRequired: true, isSelected: true)
        let model = ModelsPaneModel(inventory: inventory, usages: { [self.plugin("meetings", [usage])] })
        await model.refresh()
        let banner = try #require(model.banner)
        #expect(banner.detail == "Speech A is used by Meetings.")
        let action = try #require(banner.actions.first)
        #expect(banner.actions.count == 1)
        #expect(String(localized: action.title) == "Download Speech A")
        guard case .plugin(_, let perform) = action.destination else {
            Issue.record("the banner button must run inside the pane")
            return
        }
        await perform()
        await model.waitForDownload(Self.speechA.id)
        #expect(inventory.log == ["install:speech-a"])
        #expect(model.banner == nil)
    }

    @Test func withSeveralNeededModelsTheBannerDownloadsTheFirst() async throws {
        let usages = [Self.speechA, Self.speechB].map {
            ModelUsage(packageID: $0.id, kind: .speech, role: "x", isRequired: true, isSelected: true)
        }
        let model = ModelsPaneModel(inventory: inventory(), usages: { [self.plugin("meetings", usages)] })
        await model.refresh()
        let banner = try #require(model.banner)
        #expect(banner.title.contains("2"))
        #expect(String(localized: try #require(banner.actions.first).title) == "Download Speech A")
    }

    @Test func showInFinderRevealsTheModelsFolderThroughThePort() {
        let folder = URL(filePath: "/tmp/models", directoryHint: .isDirectory)
        let revealed = Box<[URL]>([])
        let model = ModelsPaneModel(
            inventory: inventory(), usages: { [] }, modelsDirectory: folder,
            revealInFinder: { revealed.value.append($0) })
        model.showInFinder()
        #expect(revealed.value == [folder])
    }

    @Test func storageSumsTheInstalledPackages() async {
        let inventory = inventory()
        let model = ModelsPaneModel(inventory: inventory, usages: { [] })
        await model.refresh()
        #expect(model.installedBytes == 0)
        #expect(model.storageDetail == "Nothing downloaded yet.")
        inventory.states[Self.speechA.id] = .installed
        await model.refresh()
        #expect(model.installedBytes == 100)
        #expect(model.storageDetail.hasSuffix("in Application Support"))
    }

    /// The views draw with the tokens: no raw colours, the accent fill and `onAccent` text for the primary
    /// button, the text-size font everywhere, and no global "use a model from a folder" row (D6).
    @Test func theViewsUseTokensOnly() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appending(path: path), encoding: .utf8)
        }
        let files = [
            "Sources/LintelApp/Settings/Models/ModelRow.swift", "Sources/LintelApp/Settings/Models/ModelsPane.swift",
            "Sources/LintelUI/Components/PrimaryButtonStyle.swift",
        ]
        for file in files {
            let text = try source(file)
            for raw in ["Color(red", "Color(.", "NSColor(", ".foregroundColor(", "Color.red", "Color.green", "0x"] {
                #expect(!text.contains(raw), "\(file) uses \(raw)")
            }
            #expect(!text.contains(".font(.system"), "\(file) bypasses the text size")
        }
        let primary = try source("Sources/LintelUI/Components/PrimaryButtonStyle.swift")
        #expect(primary.contains("LintelBrand.onAccent") && primary.contains("LintelBrand.accent"))
        #expect(try source("Sources/LintelApp/Settings/Models/ModelRow.swift").contains("LintelPrimaryButtonStyle()"))
        let pane = try source("Sources/LintelApp/Settings/Models/ModelsPane.swift")
        #expect(!pane.contains("Use a model from a folder"))
    }

    // MARK: Choose Folder

    @Test func chooseFolderVerifiesTheFolderAndCallsTheUsage() async {
        let inventory = inventory()
        let folder = URL(filePath: "/tmp/hand-model", directoryHint: .isDirectory)
        let chosen = Box<[URL?]>([])
        let usage = ModelUsage(
            packageID: Self.speechA.id, kind: .speech, role: "x", isRequired: true, isSelected: true,
            chooseFolder: { chosen.value.append($0) })
        let model = ModelsPaneModel(
            inventory: inventory, usages: { [self.plugin("meetings", [usage])] }, pickFolder: { folder })
        await model.refresh()
        #expect(model.rows.first { $0.id == Self.speechA.id }?.usedBy.first?.canChooseFolder == true)
        await model.chooseFolder(Self.speechA.id, for: "meetings")
        #expect(chosen.value == [folder])
        #expect(inventory.log == ["verify:speech-a"])
    }

    @Test func aCancelledFolderPickerChangesNothing() async {
        let chosen = Box(0)
        let usage = ModelUsage(
            packageID: Self.speechA.id, kind: .speech, role: "x", isRequired: true, isSelected: true,
            chooseFolder: { _ in chosen.value += 1 })
        let model = ModelsPaneModel(inventory: inventory(), usages: { [self.plugin("meetings", [usage])] })
        await model.chooseFolder(Self.speechA.id, for: "meetings")
        #expect(chosen.value == 0)
    }

    // MARK: Host and window

    @Test func theHostShowsTheModelsPanesDerivedBanner() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let host = env.makeHost([])
        await host.start()
        let usage = ModelUsage(packageID: Self.speechA.id, kind: .speech, role: "x", isRequired: true, isSelected: true)
        let models = ModelsPaneModel(inventory: inventory(), usages: { [self.plugin("meetings", [usage])] })
        await models.refresh()
        let model = SettingsHostModel(
            host: host, reader: FakePermissionsReader(),
            shellBanners: [MainWindowRouter.modelsPaneID: { models.banner }])
        model.show("general")
        #expect(model.shownBanner == nil)
        model.show(MainWindowRouter.modelsPaneID)
        #expect(model.shownBanner?.level == .attention)
    }

    @Test func theModelsEntryDrawsTheModelsPane() {
        var built = 0
        let entries = SettingsPaneAdapter.entries(
            shellPane: { _ in AnyView(EmptyView()) }, plugins: [],
            models: {
                built += 1
                return AnyView(EmptyView())
            })
        #expect(built == 0)
        _ = entries.first { $0.id == MainWindowRouter.modelsPaneID }?.makeView()
        #expect(built == 1)
    }

    @Test func theNeededBannerHasEveryPolishPluralForm() throws {
        let data = try Data(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Resources/Localizable.xcstrings"))
        let catalog = try JSONDecoder().decode(StringCatalogTests.Catalog.self, from: data)
        let entry = try #require(catalog.strings["%lld models are needed"])
        let plural = try #require(entry.localizations?["pl"]?.variations?.plural)
        #expect(Set(plural.keys) == ["one", "few", "many", "other"])
        let english = try #require(entry.localizations?["en"]?.variations?.plural)
        #expect(english["one"]?.stringUnit?.value == "%lld model is needed")
    }
}

/// The row's buttons and chips use the `lintelTextSize` tokens like its labels, and every row draws the same
/// control for "Choose Folder…".
@MainActor
@Suite struct ModelRowControlsTests {
    private func width(_ view: some View) throws -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.nsImage).size.width
    }

    private func row(folderUsers: Int) -> ModelsPaneModel.Row {
        let users = (0..<folderUsers).map {
            ModelsPaneModel.UsedBy(
                pluginID: "p\($0)", pluginName: "Plugin \($0)", role: "role", isEnabled: true, canChooseFolder: true)
        }
        return ModelsPaneModel.Row(
            model: ModelsPaneTests.speechA, state: .missing, progress: nil, errorMessage: nil, usedBy: users,
            isNeeded: false, isBusy: false)
    }

    @Test(arguments: [1, 2]) func buttonsRenderLargerAtExtraLarge(folderUsers: Int) throws {
        let view = ModelRowButtons(row: row(folderUsers: folderUsers))
        let medium = try width(view.lintelTextSize(.medium))
        let extraLarge = try width(view.lintelTextSize(.extraLarge))
        #expect(extraLarge > medium * 1.15)
    }

    @Test func chipsRenderLargerAtExtraLarge() throws {
        let chip = ModelRowChip(usedBy: try #require(row(folderUsers: 1).usedBy.first))
        let medium = try width(chip.lintelTextSize(.medium))
        let extraLarge = try width(chip.lintelTextSize(.extraLarge))
        #expect(extraLarge > medium * 1.15)
    }
}

/// Structure checks for the prototype's fidelity (the renderer cannot show a wrapped label): buttons never wrap,
/// the folder menu is bordered like the single button, the banner's primary action is accent-filled and the
/// banner shares the pane's column.
@Suite struct ModelsFidelitySourceTests {
    private static let root: URL = {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appending(path: "Sources/LintelApp/Settings/" + path), encoding: .utf8)
    }

    @Test func modelRowButtonLabelsNeverWrap() throws {
        let text = try source("Models/ModelRow.swift")
        #expect(text.contains("text.font(textSize.font(.body)).lineLimit(1).fixedSize()"))
        #expect(text.contains("ViewThatFits(in: .horizontal)"))
    }

    @Test func folderMenuIsBordered() throws {
        let text = try source("Models/ModelRow.swift")
        let menu = try #require(text.range(of: ".menuStyle(.button)"))
        #expect(text[menu.upperBound...].prefix(60).contains(".buttonStyle(LintelSecondaryButtonStyle())"))
    }

    @Test func bannerPrimaryActionIsAccentFilled() throws {
        let text = try source("Components/StatusBanner.swift")
        #expect(text.contains("LintelPrimaryButtonStyle()"))
        #expect(!text.contains("borderedProminent"))
        #expect(text.contains(".lineLimit(1).fixedSize()"))
    }

    @Test func bannerAndPaneShareOneColumn() throws {
        let text = try source("Host/SettingsHost.swift")
        #expect(text.contains(".settingsBannerColumn()"))
        #expect(text.contains(".settingsColumn()"))
        #expect(!text.contains("columnWidth"))
        #expect(text.range(of: #"\.frame\((max)?[wW]idth:\s*\d"#, options: .regularExpression) == nil)
    }
}
