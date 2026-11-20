import Foundation
import Synchronization
import Testing

@testable import DictationPlugin
@testable import LintelCore

/// A value shared with `@Sendable` closures.
final class Shared<Value: Sendable>: Sendable {
    private let box: Mutex<Value>
    init(_ value: Value) { box = Mutex(value) }
    var value: Value {
        get { box.withLock { $0 } }
        set { box.withLock { $0 = newValue } }
    }
    func update(_ change: (inout Value) -> Void) { box.withLock { change(&$0) } }
}

/// DICT-1.2 (part A of the mockup): the panel model over a real `VocabularyStore` in a temporary folder. The
/// vocabulary is invented; nothing here touches `UserDefaults`, the Keychain or the user's own files.
@MainActor
@Suite struct VocabularyPanelModelTests {
    /// A model with its store, folder and the settings the harness holds; announcements are collected.
    @MainActor final class Rig {
        let harness: DictationHarness
        let store: VocabularyStore
        let model: VocabularyPanelModel
        let settings: DictationSettings
        let spoken = Shared<[String]>([])
        let revealed = Shared<[URL]>([])
        let writeFails = Shared(false)

        init(terms: [VocabularyStore.Term] = [], file: String? = nil) throws {
            harness = try DictationHarness()
            let directory = harness.context.storageDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fails = writeFails
            store = VocabularyStore(
                directory: directory,
                write: { data, url in
                    if fails.value { throw CocoaError(.fileWriteOutOfSpace) }
                    try data.write(to: url, options: .atomic)
                })
            if let file {
                try Data(file.utf8).write(to: store.fileURL)
            } else if !terms.isEmpty {
                try store.save(terms)
            }
            store.load()
            settings = DictationSettings(harness.context.settings)
            let revealed = revealed
            model = VocabularyPanelModel(
                store: store, settings: settings, revealInFinder: { url in revealed.update { $0.append(url) } })
            let spoken = spoken
            model.announce = { text in spoken.update { $0.append(text) } }
        }

        isolated deinit { harness.tearDown() }

        var announcements: [String] { spoken.value }
        func fileTerms() -> [VocabularyStore.Term] {
            let reread = VocabularyStore(directory: harness.context.storageDirectory)
            reread.load()
            return reread.terms
        }
    }

    static let sample: [VocabularyStore.Term] = [
        .init(term: "AuthService", aliases: ["auth service", "ałt serwis"]),
        .init(term: "gRPC", aliases: ["gie er pe ce"]),
        .init(term: "Swift", aliases: []),
    ]

    private func add(_ rig: Rig, term: String, aliases: [String], pending: String = "") {
        rig.model.beginAdding()
        rig.model.fill(term: term, aliases: aliases, pending: pending)
    }

    // MARK: Adding, editing, deleting

    @Test func addingATermWithTwoAliasesWritesTheFileAndWorksAtOnce() throws {
        let rig = try Rig()
        add(rig, term: "Kubernetes", aliases: ["kubernetis", "kubernetesa"])
        rig.model.submit()
        #expect(rig.model.editor == nil)
        #expect(rig.fileTerms() == [.init(term: "Kubernetes", aliases: ["kubernetis", "kubernetesa"])])
        // The prepared replacer is the one dictation reads, so the next dictation sees the new term.
        #expect(rig.store.replacer.apply(to: "wdrażamy na kubernetis") == "wdrażamy na Kubernetes")
        #expect(rig.announcements == ["Term added. 1 terms."])
    }

    @Test func aTypedVariantIsTakenWhenAddIsPressed() throws {
        let rig = try Rig()
        add(rig, term: "Orchard", aliases: ["orczard"], pending: "orczardu")
        rig.model.submit()
        #expect(rig.fileTerms().first?.aliases == ["orczard", "orczardu"])
    }

    @Test func returnMakesATokenAndAnEmptyFieldSaves() throws {
        let rig = try Rig()
        rig.model.beginAdding()
        rig.model.setTerm("Orchard")
        rig.model.setPending("orczard")
        rig.model.returnInAliases()
        #expect(rig.model.editor?.aliases == ["orczard"])
        #expect(rig.model.editor?.pending == "")
        #expect(rig.model.editor != nil)
        rig.model.returnInAliases()
        #expect(rig.model.editor == nil)
        #expect(rig.fileTerms().map(\.term) == ["Orchard"])
    }

    @Test func backspaceInAnEmptyFieldRemovesTheLastToken() throws {
        let rig = try Rig()
        add(rig, term: "Orchard", aliases: ["orczard", "orczardu"])
        rig.model.removeLastAlias()
        #expect(rig.model.editor?.aliases == ["orczard"])
        rig.model.removeAlias(at: 0)
        #expect(rig.model.editor?.aliases == [])
        rig.model.removeLastAlias()
        #expect(rig.model.editor?.aliases == [])
    }

    @Test func aVariantGivenTwiceOrEqualToTheTermIsOneVariant() throws {
        let rig = try Rig()
        add(rig, term: "Orchard", aliases: ["orczard", "Orczard", "  orczard  ", "orchard"])
        rig.model.submit()
        #expect(rig.fileTerms().first?.aliases == ["orczard"])
    }

    @Test func editingKeepsThePlaceAndOtherEntries() throws {
        let rig = try Rig(terms: Self.sample)
        rig.model.beginEditing(1)
        #expect(rig.model.editor?.term == "gRPC")
        rig.model.fill(term: "gRPC", aliases: ["gie er pe ce", "dżi ar pi si"])
        rig.model.submit()
        #expect(rig.fileTerms().map(\.term) == ["AuthService", "gRPC", "Swift"])
        #expect(rig.fileTerms()[1].aliases == ["gie er pe ce", "dżi ar pi si"])
        #expect(rig.announcements == ["gRPC saved."])
    }

    @Test func savingAnEntryUnderItsOwnTermIsNotAConflict() throws {
        let rig = try Rig(terms: Self.sample)
        rig.model.beginEditing(0)
        rig.model.fill(term: "authservice", aliases: ["auth service"])
        rig.model.submit()
        #expect(rig.model.editor == nil)
        #expect(rig.fileTerms()[0].term == "authservice")
    }

    @Test func deletingAsksFirstAndCancelChangesNothing() throws {
        let rig = try Rig(terms: Self.sample)
        rig.model.requestDelete(0)
        #expect(rig.model.pendingDeletion?.term == "AuthService")
        #expect(rig.model.pendingDeletion?.aliases.count == 2)
        rig.model.cancelDelete()
        #expect(rig.model.pendingDeletion == nil)
        #expect(rig.fileTerms().count == 3)
        rig.model.requestDelete(0)
        rig.model.confirmDelete()
        #expect(rig.fileTerms().map(\.term) == ["gRPC", "Swift"])
        #expect(rig.announcements == ["AuthService deleted."])
        #expect(rig.store.replacer.apply(to: "auth service") == "auth service")
    }

    // MARK: Validation (D6, D7)

    @Test func anEmptyTermIsRejectedAfterTheButtonAndTheFocusGoesThere() throws {
        let rig = try Rig()
        add(rig, term: "  ", aliases: ["kubernetis"])
        rig.model.submit()
        #expect(rig.model.editor != nil)
        #expect(rig.model.termMessage == "Type how the term should be written.")
        #expect(rig.model.editor?.focus == .term)
        #expect(rig.announcements == ["Type how the term should be written."])
        #expect(!FileManager.default.fileExists(atPath: rig.store.fileURL.path))
    }

    @Test func aDuplicateTermIsRejectedWithoutRegardToCaseAndShowPointsAtIt() throws {
        let rig = try Rig(terms: Self.sample)
        add(rig, term: "AUTHSERVICE", aliases: [])
        rig.model.submit()
        #expect(rig.model.termMessage == "“AuthService” is already in the vocabulary.")
        #expect(rig.model.duplicateRowID == 0)
        rig.model.query = "x"
        rig.model.showDuplicate()
        #expect(rig.model.query == "")
        #expect(rig.model.highlightedID == 0)
        #expect(rig.model.editor != nil)
        #expect(rig.fileTerms().count == 3)
    }

    @Test func aVariantBelongingToAnotherTermIsRejected() throws {
        let rig = try Rig(terms: Self.sample)
        add(rig, term: "AuthServer", aliases: ["Auth  Service", "auth serwer"])
        rig.model.submit()
        #expect(
            rig.model.aliasMessage
                == "“Auth Service” already belongs to AuthService. A variant can point to one term only.")
        #expect(rig.model.editor?.badAlias == "Auth Service")
        #expect(rig.model.editor?.focus == .aliases)
        #expect(rig.fileTerms().count == 3)
    }

    @Test func aVariantEqualToAnotherTermIsRejected() throws {
        let rig = try Rig(terms: Self.sample)
        add(rig, term: "SwiftUI", aliases: ["swift ui", "swift"])
        rig.model.submit()
        #expect(rig.model.aliasMessage == "“swift” is the term Swift. It would turn every Swift into SwiftUI.")
    }

    @Test func aTermEqualToAnotherEntrysVariantIsRejected() throws {
        let rig = try Rig(terms: Self.sample)
        add(rig, term: "Ałt Serwis", aliases: [])
        rig.model.submit()
        #expect(rig.model.termMessage == "“Ałt Serwis” is already a spoken variant of AuthService.")
    }

    @Test func aVariantOfMoreThanEightWordsIsRejectedAndEightIsAllowed() throws {
        let rig = try Rig()
        add(rig, term: "RFC 9110", aliases: ["er ef ce dziewięć tysięcy sto dziesięć http"])
        rig.model.submit()
        #expect(rig.model.aliasMessage == nil)
        #expect(rig.model.editor == nil)

        add(rig, term: "RFC 9111", aliases: ["er ef ce dziewięć tysięcy sto jedenaście http semantics"])
        rig.model.submit()
        #expect(rig.model.aliasMessage == "A variant can have at most 8 words.")
        #expect(rig.fileTerms().count == 1)
    }

    @Test func aVariantWithoutAWordIsRejected() throws {
        let rig = try Rig()
        add(rig, term: "Orchard", aliases: ["…"])
        rig.model.submit()
        #expect(rig.model.aliasMessage == "“…” has no letter or digit, so it could never match.")
    }

    @Test func aTermWithoutVariantsIsAllowed() throws {
        let rig = try Rig()
        add(rig, term: "Verdigris", aliases: [])
        rig.model.submit()
        #expect(rig.fileTerms() == [.init(term: "Verdigris", aliases: [])])
        #expect(rig.store.replacer.apply(to: "a verdigris wall") == "a Verdigris wall")
    }

    @Test func aProblemClearsWhenTheFieldChanges() throws {
        let rig = try Rig(terms: Self.sample)
        add(rig, term: "Swift", aliases: [])
        rig.model.submit()
        #expect(rig.model.termMessage != nil)
        rig.model.setTerm("Swifty")
        #expect(rig.model.termMessage == nil)
        rig.model.submit()
        #expect(rig.fileTerms().count == 4)
    }

    // MARK: Short variants (D8)

    @Test func aShortSingleWordVariantNeedsConfirmationAndAddWaitsForIt() throws {
        let rig = try Rig()
        add(rig, term: "Zed", aliases: ["zet", "zed edytor"])
        #expect(rig.model.unconfirmedShortAliases == ["zet"])
        #expect(!rig.model.canSubmit)
        rig.model.submit()
        #expect(rig.model.editor != nil)
        #expect(rig.fileTerms().isEmpty)
        rig.model.setShortAliasesConfirmed(true)
        #expect(rig.model.canSubmit)
        rig.model.submit()
        #expect(rig.fileTerms().first?.aliases == ["zet", "zed edytor"])
    }

    @Test func onlyVariantsAreChecked_notTheTermAndNotMultiWordVariants() throws {
        let rig = try Rig()
        add(rig, term: "Go", aliases: ["go lang", "gołang"])
        #expect(rig.model.unconfirmedShortAliases.isEmpty)
        #expect(rig.model.canSubmit)
        #expect(VocabularyRules.shortAliases(["abc", "abcd", "ab cd", "42", "ok"]) == ["abc", "42", "ok"])
    }

    @Test func aTypedShortVariantCountsBeforeItBecomesAToken() throws {
        let rig = try Rig()
        add(rig, term: "Zed", aliases: [], pending: "zet")
        #expect(!rig.model.canSubmit)
    }

    @Test func removingTheShortVariantRemovesTheWarning() throws {
        let rig = try Rig()
        add(rig, term: "Zed", aliases: ["zet"])
        #expect(!rig.model.canSubmit)
        rig.model.removeLastAlias()
        #expect(rig.model.canSubmit)
        #expect(rig.model.unconfirmedShortAliases.isEmpty)
    }

    @Test func aShortVariantTheEntryAlreadyHadAsksNothingButANewOneDoes() throws {
        let rig = try Rig(terms: [.init(term: "Zed", aliases: ["zet"])])
        rig.model.beginEditing(0)
        #expect(rig.model.canSubmit)
        #expect(rig.model.unconfirmedShortAliases.isEmpty)
        rig.model.fill(term: "Zed", aliases: ["zet", "zd"])
        #expect(rig.model.unconfirmedShortAliases == ["zd"])
        #expect(!rig.model.canSubmit)
    }

    // MARK: Limits

    @Test func theLimitOf2000TermsBlocksAddingAndSaveRefusesMore() throws {
        let terms = (1...VocabularyStore.maximumTerms).map { VocabularyStore.Term(term: "Term \($0)", aliases: []) }
        let rig = try Rig(terms: terms)
        #expect(rig.model.limitReached)
        #expect(!rig.model.canAdd)
        rig.model.beginAdding()
        #expect(rig.model.editor == nil)
        #expect(throws: VocabularyStore.SaveError.tooManyTerms) {
            try rig.store.save(terms + [.init(term: "One more", aliases: [])])
        }
        // Editing and deleting still work, and deleting makes room.
        rig.model.requestDelete(0)
        rig.model.confirmDelete()
        #expect(rig.model.canAdd)
    }

    // MARK: Search and order (D11)

    private func longTerms(_ count: Int) -> [VocabularyStore.Term] {
        (1...count).map { .init(term: "Item \(String(format: "%02d", $0))", aliases: ["pozycja \($0)"]) }
    }

    @Test func theListIsAlphabeticalIgnoringCase() throws {
        let rig = try Rig(terms: [
            .init(term: "Zed", aliases: []), .init(term: "gRPC", aliases: []), .init(term: "AuthService", aliases: []),
        ])
        #expect(rig.model.allRows.map(\.term) == ["AuthService", "gRPC", "Zed"])
    }

    @Test func searchAppearsFromTenEntries() throws {
        #expect(try !Rig(terms: longTerms(9)).model.showsSearch)
        #expect(try Rig(terms: longTerms(10)).model.showsSearch)
    }

    @Test func searchMatchesTermsAndVariantsWithoutCaseOrDiacritics() throws {
        var terms = longTerms(10)
        terms.append(.init(term: "Nextcloud", aliases: ["nekst klałd", "post klałd"]))
        terms.append(.init(term: "PostgreSQL", aliases: ["postgres"]))
        terms.append(.init(term: "Łódź", aliases: ["lodz"]))
        let rig = try Rig(terms: terms)
        rig.model.query = "POST"
        #expect(rig.model.visibleRows.map(\.term) == ["Nextcloud", "PostgreSQL"])
        #expect(rig.model.isSearching)
        rig.model.query = "lodz"
        #expect(rig.model.visibleRows.map(\.term) == ["Łódź"])
        rig.model.query = "wrzos"
        #expect(rig.model.visibleRows.isEmpty)
        rig.model.query = "   "
        #expect(!rig.model.isSearching)
        #expect(rig.model.visibleRows.count == terms.count)
    }

    @Test func noMatchOffersToAddTheSearchedText() throws {
        let rig = try Rig(terms: longTerms(10))
        rig.model.query = "wrzos"
        #expect(rig.model.visibleRows.isEmpty)
        rig.model.beginAdding(term: "wrzos")
        #expect(rig.model.editor?.term == "wrzos")
        #expect(rig.model.editor?.focus == .aliases)
    }

    @Test func aNewEntryThatTheSearchHidesClearsTheSearch() throws {
        let rig = try Rig(terms: longTerms(10))
        rig.model.query = "pozycja"
        add(rig, term: "Wrzos", aliases: ["wrzos"])
        rig.model.submit()
        #expect(rig.model.query == "")
        #expect(rig.model.visibleRows.contains { $0.term == "Wrzos" })
    }

    @Test func belowTenEntriesAStaleQueryDoesNotFilter() throws {
        let rig = try Rig(terms: longTerms(3))
        rig.model.query = "zzz"
        #expect(!rig.model.isSearching)
        #expect(rig.model.visibleRows.count == 3)
    }

    // MARK: Keyboard on the list (D13)

    @Test func arrowsMoveBetweenVisibleRowsAndReturnOrDeleteActOnTheSelectedOne() throws {
        let rig = try Rig(terms: Self.sample)
        rig.model.moveSelection(by: 1)
        #expect(rig.model.selectedID == 0)
        rig.model.moveSelection(by: 1)
        #expect(rig.model.selectedID == 1)
        rig.model.moveSelection(by: 5)
        #expect(rig.model.selectedID == 2)
        rig.model.moveSelection(by: -1)
        rig.model.editSelected()
        #expect(rig.model.editor?.target == .editing(1))
        rig.model.cancelEditing()
        #expect(rig.model.editor == nil)
        #expect(rig.model.selectedID == 1)
        rig.model.deleteSelected()
        #expect(rig.model.pendingDeletion?.term == "gRPC")
    }

    // MARK: Example (D5)

    @Test func theExampleIsBuiltByTheRealReplacerFromTheFirstUsableVariant() throws {
        let rig = try Rig()
        add(rig, term: "AuthService", aliases: ["auth service", "ałt serwis"])
        let example = try #require(rig.model.example)
        #expect(example.heard == "open auth service now")
        #expect(example.inserted == "open AuthService now")
        rig.model.fill(term: "AuthService", aliases: [], pending: "")
        #expect(rig.model.example == nil)
        rig.model.fill(term: "", aliases: ["auth service"])
        #expect(rig.model.example == nil)
        rig.model.fill(term: "AuthService", aliases: ["a b c d e f g h i"])
        #expect(rig.model.example == nil)
        rig.model.fill(term: "AuthService", aliases: ["a b c d e f g h i", "auth service"])
        #expect(rig.model.example?.heard == "open auth service now")
    }

    // MARK: Saving fails (D12.3)

    @Test func aFailedWriteKeepsTheFormWithItsTextAndTheListAsItWas() throws {
        let rig = try Rig(terms: Self.sample)
        rig.writeFails.value = true
        add(rig, term: "Orchard", aliases: ["orczard", "orczardu"])
        rig.model.submit()
        #expect(rig.model.editor?.saveFailed == true)
        #expect(rig.model.editor?.term == "Orchard")
        #expect(rig.model.editor?.aliases == ["orczard", "orczardu"])
        #expect(rig.model.entries.count == 3)
        #expect(rig.announcements.last == "The term couldn’t be saved. Check that the disk isn’t full.")
        #expect(rig.store.terms.count == 3)

        rig.writeFails.value = false
        rig.model.submit()
        #expect(rig.model.editor == nil)
        #expect(rig.fileTerms().count == 4)
    }

    @Test func aFailedDeleteKeepsTheTerm() throws {
        let rig = try Rig(terms: Self.sample)
        rig.writeFails.value = true
        rig.model.requestDelete(0)
        rig.model.confirmDelete()
        #expect(rig.model.entries.count == 3)
        #expect(rig.fileTerms().count == 3)
    }

    // MARK: The file (D12)

    @Test func aDamagedFileShowsAOneTimeNoticeWithTheCopy() throws {
        let rig = try Rig(file: "{ not json")
        #expect(rig.model.notice == .setAside)
        #expect(rig.model.entries.isEmpty)
        #expect(rig.model.canEdit)
        #expect(FileManager.default.fileExists(atPath: rig.store.corruptCopyURL.path))
        rig.model.showCopyInFinder()
        #expect(rig.revealed.value == [rig.store.corruptCopyURL])
        // Adding a term does not make the notice go away; Dismiss does.
        add(rig, term: "Orchard", aliases: [])
        rig.model.submit()
        #expect(rig.model.notice == .setAside)
        rig.model.dismissNotice()
        #expect(rig.model.notice == nil)
    }

    @Test func aFileFromANewerVersionIsReadOnlyEverywhere() throws {
        let rig = try Rig(file: #"{"version":2,"terms":[{"term":"AuthService","aliases":["auth service"]}]}"#)
        #expect(rig.model.notice == .newerVersion)
        #expect(rig.model.isReadOnly)
        #expect(!rig.model.canEdit)
        #expect(!rig.model.canAdd)
        #expect(rig.model.entries.count == 1)
        rig.model.beginAdding()
        rig.model.beginEditing(0)
        rig.model.requestDelete(0)
        #expect(rig.model.editor == nil)
        #expect(rig.model.pendingDeletion == nil)
        // The terms are still used.
        #expect(rig.store.replacer.apply(to: "auth service") == "AuthService")
        // And the file is untouched.
        let text = try String(contentsOf: rig.store.fileURL, encoding: .utf8)
        #expect(text.contains(#""version":2"#))
    }

    @Test func anUnreadableFileIsReadOnlyWithItsOwnNotice() throws {
        let rig = try Rig()
        // A folder where the file should be cannot be read as a file.
        try FileManager.default.createDirectory(at: rig.store.fileURL, withIntermediateDirectories: true)
        rig.store.load()
        rig.model.reload()
        #expect(rig.model.notice == .unreadable)
        #expect(!rig.model.canEdit)
        try FileManager.default.removeItem(at: rig.store.fileURL)
    }

    @Test func aNormalFileHasNoNotice() throws {
        let rig = try Rig(terms: Self.sample)
        #expect(rig.model.notice == nil)
        #expect(rig.model.canEdit)
    }

    // MARK: The switch (D9)

    @Test func theSwitchIsTheSettingAndTheListStaysEditableWhileItIsOff() throws {
        let rig = try Rig(terms: Self.sample)
        #expect(rig.model.isEnabled)
        rig.model.isEnabled = false
        #expect(!rig.settings.vocabularyEnabled)
        #expect(rig.model.canEdit)
        #expect(rig.model.canAdd)
        add(rig, term: "Orchard", aliases: [])
        rig.model.submit()
        #expect(rig.fileTerms().count == 4)
        rig.model.isEnabled = true
        #expect(rig.settings.vocabularyEnabled)
    }

    @Test func reloadReadsWhatTheStoreHoldsAndTheSwitch() throws {
        let rig = try Rig()
        try rig.store.save(Self.sample)
        rig.settings.setVocabularyEnabled(false)
        rig.model.reload()
        #expect(rig.model.entries.count == 3)
        #expect(!rig.model.isEnabled)
    }
}

@Suite struct VocabularyRulesTests {
    @Test func keysIgnoreCaseDiacriticsAndWhiteSpaceButNotPunctuation() {
        #expect(VocabularyRules.key("Auth  Service") == VocabularyRules.key("auth service"))
        #expect(VocabularyRules.key("Zażółć") == VocabularyRules.key("zazolc"))
        #expect(VocabularyRules.key("e-mail") != VocabularyRules.key("e mail"))
        #expect(VocabularyRules.key("…") == "")
    }

    @Test func wordsAreRunsOfLettersAndDigits() {
        #expect(VocabularyRules.words(in: "llama.cpp b11600") == ["llama", "cpp", "b11600"])
        #expect(VocabularyRules.words(in: "  ").isEmpty)
    }

    @Test func matchRangesFoldLettersLikeTheSearch() {
        let text = "nekst kład"
        #expect(VocabularyRules.matchRanges(of: "klad", in: text).map { String(text[$0]) } == ["kład"])
        #expect(VocabularyRules.matchRanges(of: "KŁAD", in: text).map { String(text[$0]) } == ["kład"])
        let postgres = "post gres ku el"
        #expect(VocabularyRules.matchRanges(of: "post", in: "PostgreSQL").map { String("PostgreSQL"[$0]) } == ["Post"])
        #expect(VocabularyRules.matchRanges(of: "e", in: postgres).count == 2)
        #expect(VocabularyRules.matchRanges(of: "  ", in: text).isEmpty)
        #expect(VocabularyRules.matchRanges(of: "wrzos", in: text).isEmpty)
        // Every row the search shows has its match marked.
        let entry = VocabularyStore.Term(term: "Nextcloud", aliases: ["nekst kład"])
        #expect(VocabularyRules.matches(entry, query: "klad"))
    }

    @Test func checkIgnoresTheEntryBeingEdited() {
        let entries = [VocabularyStore.Term(term: "A", aliases: ["a a"]), .init(term: "B", aliases: [])]
        #expect(VocabularyRules.check(term: "A", aliases: ["a a"], ignoring: 0, in: entries).isValid)
        #expect(!VocabularyRules.check(term: "A", aliases: [], ignoring: 1, in: entries).isValid)
    }
}

/// The Vocabulary sources follow the repository's rules for plugin code and panes.
@Suite struct VocabularySourceRulesTests {
    static let root: URL = {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }()

    private static func sources() throws -> [(name: String, text: String)] {
        let folder = root.appending(path: "Sources/DictationPlugin/Vocabulary")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        return try names.map { ($0, try String(contentsOf: folder.appending(path: $0), encoding: .utf8)) }
    }

    /// Code without comments and DEBUG-only QA code.
    private static func code(_ text: String) -> [String] {
        var inDebug = false
        var lines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "#if DEBUG" { inDebug = true }
            if !inDebug { lines.append(line.components(separatedBy: "//").first ?? "") }
            if trimmed == "#endif" { inDebug = false }
        }
        return lines
    }

    @Test func noTrapsAndNoLoggingOfTheUsersWords() throws {
        for (name, text) in try Self.sources() {
            for line in Self.code(text) {
                #expect(!line.contains("fatalError"), "\(name): fatalError")
                #expect(!line.contains("try!"), "\(name): try!")
                #expect(!line.contains("logger."), "\(name): the vocabulary is never logged")
                #expect(!line.contains("print("), "\(name): print")
            }
        }
    }

    @Test func colourAndTextSizesGoThroughTheBrandAndTheTextSizeTokens() throws {
        for (name, text) in try Self.sources() {
            for line in Self.code(text) {
                #expect(
                    line.range(
                        of:
                            #"\.(secondary|tertiary|quaternary)\b|separatorColor|controlBackgroundColor|\.windowBackgroundColor|SystemFill\b|\bDivider\(\)|foregroundStyle\(\.(orange|red|green|yellow|blue)\)"#,
                        options: .regularExpression) == nil,
                    "\(name): \(line)")
                #expect(
                    line.range(of: #"(?<!textSize)\.font\(\."#, options: .regularExpression) == nil,
                    "\(name): text sizes go through textSize.font: \(line)")
            }
        }
    }

    @Test func theQAStatesExistOnlyInDebugBuilds() throws {
        let qa = try #require(try Self.sources().first { $0.name == "VocabularyQA.swift" })
        #expect(qa.text.hasPrefix("#if DEBUG"))
        let plugin = try String(
            contentsOf: Self.root.appending(path: "Sources/DictationPlugin/DictationPlugin.swift"), encoding: .utf8)
        #expect(
            plugin.range(of: #"#if DEBUG\s+vocabulary = VocabularyQA\.makeStore"#, options: .regularExpression) != nil)
    }
}

/// The pane draws the section between Basics and Advanced.
@MainActor
@Suite struct VocabularyPaneIntegrationTests {
    @Test func theDictationPaneContainsTheVocabularySectionAfterBasics() throws {
        let source = try String(
            contentsOf: VocabularySourceRulesTests.rootURL.appending(
                path: "Sources/DictationPlugin/DictationSettingsPane.swift"), encoding: .utf8)
        let basics = try #require(source.range(of: "\"Basics\""))
        let section = try #require(source.range(of: "VocabularySection(model: vocabulary"))
        let advanced = try #require(source.range(of: "} advanced: {"))
        #expect(basics.lowerBound < section.lowerBound)
        #expect(section.lowerBound < advanced.lowerBound)
    }
}

extension VocabularySourceRulesTests {
    static var rootURL: URL { root }
}

/// What `VocabularyStore` now says about its file (DICT-1.2, D12); loading and saving are unchanged.
@Suite struct VocabularyStoreConditionTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "vocab-condition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aPlainOrMissingFileIsNormal() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(directory: directory)
        store.load()
        #expect(store.condition == .normal)
        try store.save([.init(term: "AuthService", aliases: [])])
        #expect(store.condition == .normal)
        store.load()
        #expect(store.condition == .normal)
    }

    @Test func aDamagedFileIsSetAsideAndTheFlagSurvivesASave() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(directory: directory)
        try Data("broken".utf8).write(to: store.fileURL)
        store.load()
        #expect(store.condition == .setAside)
        #expect(FileManager.default.fileExists(atPath: store.corruptCopyURL.path))
        #expect(!store.isReadOnly)
        try store.save([.init(term: "AuthService", aliases: [])])
        #expect(store.condition == .setAside)
        // The next launch reads a good file: no flag.
        store.load()
        #expect(store.condition == .normal)
    }

    @Test func aNewerVersionIsFlaggedReadOnlyAndNeverWritten() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(directory: directory)
        let text = #"{"version":9,"terms":[{"term":"AuthService","aliases":[]}]}"#
        try Data(text.utf8).write(to: store.fileURL)
        store.load()
        #expect(store.condition == .newerVersion)
        #expect(store.isReadOnly)
        #expect(throws: VocabularyStore.SaveError.readOnly) { try store.save([]) }
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == text)
    }

    @Test func aFileThatCannotBeReadIsFlaggedAndLeftAlone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(directory: directory)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        store.load()
        #expect(store.condition == .unreadable)
        #expect(store.isReadOnly)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func aDamagedFileThatCannotBeMovedIsLeftAloneAndNeverOverwritten() throws {
        let directory = try makeDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = VocabularyStore(directory: directory)
        try Data("broken".utf8).write(to: store.fileURL)
        // A folder that can be read but not changed: the damaged file cannot be renamed to the copy.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        store.load()
        #expect(store.condition == .unreadable)
        #expect(store.isReadOnly)
        #expect(throws: VocabularyStore.SaveError.readOnly) { try store.save([.init(term: "A", aliases: [])]) }
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == "broken")
    }

    @Test func eraseClearsTheFlag() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(directory: directory)
        try Data("broken".utf8).write(to: store.fileURL)
        store.load()
        try store.erase()
        #expect(store.condition == .normal)
        #expect(!FileManager.default.fileExists(atPath: store.corruptCopyURL.path))
    }

    @Test func aFailingWriterThrowsAndKeepsWhatWasThere() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(directory: directory, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        #expect(throws: VocabularyStore.SaveError.write) { try store.save([.init(term: "A", aliases: [])]) }
        #expect(store.terms.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}

/// Every sentence of the Vocabulary section is in the String Catalog in English and Polish. The literals are read
/// from the sources; an interpolation counts as one placeholder whatever its type.
@Suite struct VocabularyStringCatalogTests {
    /// The string literals that follow `Text(`, `localized:` or `LocalizedStringResource(`, with `\(…)` as `%`.
    static func keys(in source: String) -> [String] {
        let chars = Array(source)
        var keys: [String] = []
        let openers = ["Text(", "localized:", "LocalizedStringResource("]
        var index = 0
        while index < chars.count {
            guard let opener = openers.first(where: { matches($0, in: chars, at: index) }) else {
                index += 1
                continue
            }
            var cursor = index + opener.count
            while cursor < chars.count, chars[cursor].isWhitespace { cursor += 1 }
            index = cursor
            guard cursor < chars.count, chars[cursor] == "\"" else { continue }
            cursor += 1
            var key = ""
            var depth = 0
            while cursor < chars.count {
                let character = chars[cursor]
                if depth == 0 {
                    if character == "\"" { break }
                    if character == "\\", cursor + 1 < chars.count, chars[cursor + 1] == "(" {
                        depth = 1
                        key += "%"
                        cursor += 2
                        continue
                    }
                    key.append(character)
                } else {
                    if character == "(" { depth += 1 }
                    if character == ")" { depth -= 1 }
                }
                cursor += 1
            }
            keys.append(key)
            index = cursor + 1
        }
        return keys
    }

    private static func matches(_ word: String, in chars: [Character], at index: Int) -> Bool {
        let letters = Array(word)
        guard index + letters.count <= chars.count else { return false }
        return Array(chars[index..<(index + letters.count)]) == letters
    }

    @Test func everyLiteralIsTranslated() throws {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        let catalog = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: url.appending(path: "Resources/Localizable.xcstrings"))) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        // Catalog keys with the placeholder types folded.
        var known: Set<String> = []
        for key in strings.keys {
            known.insert(key.replacingOccurrences(of: "%lld", with: "%").replacingOccurrences(of: "%@", with: "%"))
        }
        let folder = url.appending(path: "Sources/DictationPlugin/Vocabulary")
        var found = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: folder.appending(path: name), encoding: .utf8)
            for key in Self.keys(in: text) where !key.isEmpty {
                found += 1
                #expect(known.contains(key), "\(name): “\(key)” is not in Localizable.xcstrings")
            }
        }
        #expect(found > 60)
    }
}
