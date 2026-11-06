import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

private func ids(_ rows: [NoteRow]) -> [String] { rows.map { $0.id.key.rawValue } }

@Suite("NoteLibrary: merging and paging")
struct NoteLibraryMergeTests {
    @Test("sources and manual notes merge newest first, and a source's own key is its row")
    func merge() async throws {
        let meetings = ScriptedNoteSource(
            "meetings",
            items: [
                Fixtures.summary("meetings", "a", secondsAgo: 100), Fixtures.summary("meetings", "c", secondsAgo: 300),
            ])
        let dictation = ScriptedNoteSource(
            "dictation", items: [Fixtures.summary("dictation", "s/1", secondsAgo: 200, kind: .dictation)])
        let store = FakeOverlayStore(present: [Fixtures.manual(1, "m", secondsAgo: 250, title: "Plan")])
        let library = NoteLibrary(box: SourceBox([meetings, dictation]), store: store)
        let listing = await library.list(matching: nil, after: nil, limit: 10)
        #expect(ids(listing.rows) == ["meetings:a", "dictation:s/1", "notes:m", "meetings:c"])
        #expect(listing.total == 4)
        #expect(listing.next == nil)
        #expect(listing.unavailable.isEmpty)
        #expect(listing.rows[2].summary.kind == .manual)
        #expect(listing.rows[2].summary.title == "Plan")
    }

    @Test("a cursor pages across sources in one global order, with every row once")
    func paging() async throws {
        var meetingItems: [NoteSummary] = []
        var dictationItems: [NoteSummary] = []
        for index in 0..<7 {
            meetingItems.append(Fixtures.summary("meetings", "m\(index)", secondsAgo: Double(index) * 20))
            dictationItems.append(
                Fixtures.summary("dictation", "d/\(index)", secondsAgo: Double(index) * 20 + 7, kind: .dictation))
        }
        let library = NoteLibrary(
            box: SourceBox([
                ScriptedNoteSource("meetings", items: meetingItems),
                ScriptedNoteSource("dictation", items: dictationItems),
            ]))
        let expected = (meetingItems + dictationItems).sorted { $0.startedAt > $1.startedAt }.map(\.id.rawValue)
        var collected: [String] = []
        var cursor: NoteListCursor?
        var pages = 0
        repeat {
            let page = await library.list(matching: nil, after: cursor, limit: 3)
            #expect(page.rows.count <= 3)
            #expect(page.total == 14)
            collected += ids(page.rows)
            cursor = page.next
            pages += 1
        } while cursor != nil && pages < 20
        #expect(collected == expected)
        #expect(pages == 5)
    }

    @Test("a query goes to the sources and manual notes are not part of it")
    func query() async throws {
        let meetings = ScriptedNoteSource(
            "meetings",
            items: [
                Fixtures.summary("meetings", "a", secondsAgo: 1, title: "Budget review"),
                Fixtures.summary("meetings", "b", secondsAgo: 2, title: "Standup"),
            ])
        let store = FakeOverlayStore(present: [Fixtures.manual(1, "m", secondsAgo: 5, title: "Budget plan")])
        let library = NoteLibrary(box: SourceBox([meetings]), store: store)
        let listing = await library.list(
            matching: NormalizedQuery(raw: "Budget", normalized: "budget"), after: nil, limit: 10)
        #expect(ids(listing.rows) == ["meetings:a"])
    }

    @Test("a repeated key and a key of another plugin in a source's items are dropped")
    func foreignItems() async throws {
        let meetings = ScriptedNoteSource(
            "meetings",
            items: [
                Fixtures.summary("meetings", "a", secondsAgo: 1),
                Fixtures.summary("dictation", "s/1", secondsAgo: 2),
                Fixtures.summary("meetings", "a", secondsAgo: 3),
            ])
        let library = NoteLibrary(box: SourceBox([meetings]))
        let listing = await library.list(matching: nil, after: nil, limit: 10)
        #expect(ids(listing.rows) == ["meetings:a"])
    }

    @Test("a source can be asked for the owner of a key")
    func routing() async throws {
        let meetings = ScriptedNoteSource("meetings")
        let library = NoteLibrary(box: SourceBox([meetings]))
        await library.refreshSources()
        #expect(await library.source(for: Fixtures.key("meetings", "x"))?.pluginID == "meetings")
        #expect(await library.source(for: Fixtures.key("dictation", "x")) == nil)
    }

    @Test("every state has its badge, ready has none")
    func badges() {
        let states: [(NoteState, NoteBadge?)] = [
            (.ready, nil), (.recording, .recording), (.processing, .processing),
            (.writing(done: 2, of: 5), .writing(done: 2, of: 5)),
            (.partial, .partial), (.stale, .stale), (.interrupted, .interrupted), (.failed, .failed),
            (.needsModel, .needsModel),
        ]
        for (state, badge) in states { #expect(NoteBadge(state: state) == badge) }
    }

    @Test("rows carry the badge of their source's state")
    func rowBadges() async throws {
        let meetings = ScriptedNoteSource(
            "meetings",
            items: [
                Fixtures.summary("meetings", "a", secondsAgo: 1, state: .writing(done: 1, of: 3)),
                Fixtures.summary("meetings", "b", secondsAgo: 2),
            ])
        let listing = await NoteLibrary(box: SourceBox([meetings])).list(matching: nil, after: nil, limit: 5)
        #expect(listing.rows.map(\.badge) == [.writing(done: 1, of: 3), nil])
    }
}

@Suite("NoteLibrary: budget and failures")
struct NoteLibraryBudgetTests {
    @Test("a source that does not answer within its budget is unavailable, the others are listed")
    func budgetCut() async throws {
        let fast = ScriptedNoteSource("meetings", items: [Fixtures.summary("meetings", "a", secondsAgo: 1)])
        let slow = ScriptedNoteSource("dictation", items: [Fixtures.summary("dictation", "s/1", secondsAgo: 2)])
        slow.behavior = .hangs
        let clock = ManualClock()
        let library = NoteLibrary(box: SourceBox([fast, slow]), clock: clock)
        let task = Task { await library.list(matching: nil, after: nil, limit: 10) }
        // Time moves only here; the budget fires once both sources have been asked.
        // Both sources were asked and each has set its deadline.
        await clock.waitForSleeps(2)
        // The answering source's deadline is cancelled once it answered; only the hanging one's is left to fire.
        await clock.waitForCancelledSleeps(1)
        clock.advance(by: .milliseconds(150))
        let listing = await task.value
        #expect(ids(listing.rows) == ["meetings:a"])
        #expect(listing.unavailable == [UnavailableSource(pluginID: "dictation", reason: .timedOut)])
    }

    @Test("a source that throws is unavailable, never gone, and the next page asks it again")
    func throwing() async throws {
        let meetings = ScriptedNoteSource("meetings", items: [Fixtures.summary("meetings", "a", secondsAgo: 1)])
        let dictation = ScriptedNoteSource("dictation", items: [Fixtures.summary("dictation", "s/1", secondsAgo: 2)])
        dictation.behavior = .throwsError
        let store = FakeOverlayStore(present: [
            Fixtures.overlay(
                1, Fixtures.key("dictation", "s/1"), layer: "cleaned", startedAt: Fixtures.epoch.addingTimeInterval(-2))
        ])
        let library = NoteLibrary(box: SourceBox([meetings, dictation]), store: store)
        let first = await library.list(matching: nil, after: nil, limit: 10)
        #expect(ids(first.rows).first == "meetings:a")
        #expect(first.unavailable == [UnavailableSource(pluginID: "dictation", reason: .failed)])
        #expect(first.next == nil, "nothing is left to page for the source that did not answer")
        // Its kept overlay is shown read-only, as for a source that is off.
        #expect(first.rows.contains { $0.id == .live(Fixtures.key("dictation", "s/1")) && $0.isReadOnly })
        #expect(store.detachCalls.isEmpty)
        dictation.behavior = .answers
        let second = await library.list(matching: nil, after: nil, limit: 10)
        #expect(ids(second.rows) == ["meetings:a", "dictation:s/1"])
        #expect(second.unavailable.isEmpty)
        #expect(second.rows[1].isReadOnly == false)
    }

    @Test("an unreadable overlay store lists the sources without overlays and says so")
    func unreadableIndex() async throws {
        let meetings = ScriptedNoteSource("meetings", items: [Fixtures.summary("meetings", "a", secondsAgo: 1)])
        let store = FakeOverlayStore()
        store.failReads = true
        let listing = await NoteLibrary(box: SourceBox([meetings]), store: store).list(
            matching: nil, after: nil, limit: 5)
        #expect(ids(listing.rows) == ["meetings:a"])
        #expect(listing.overlaysAvailable == false)
        #expect(store.detachCalls.isEmpty)
    }

    @Test("parallel listings of one library are safe")
    func parallel() async throws {
        var items: [NoteSummary] = []
        for index in 0..<30 { items.append(Fixtures.summary("meetings", "m\(index)", secondsAgo: Double(index))) }
        let library = NoteLibrary(box: SourceBox([ScriptedNoteSource("meetings", items: items)]))
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    var total = 0
                    var cursor: NoteListCursor?
                    repeat {
                        let page = await library.list(matching: nil, after: cursor, limit: 7)
                        total += page.rows.count
                        cursor = page.next
                    } while cursor != nil
                    return total
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(counts.allSatisfy { $0 == 30 })
    }
}

@Suite("NoteLibrary: set of sources")
struct NoteLibrarySourceSetTests {
    @Test("a duplicate or mismatched id is dropped, only the first source of an id is asked, nothing detaches")
    func dropped() async throws {
        let key = Fixtures.key("meetings", "a")
        let first = ScriptedNoteSource("meetings", items: [Fixtures.summary("meetings", "a", secondsAgo: 1)])
        let second = ScriptedNoteSource("meetings", items: [Fixtures.summary("meetings", "z", secondsAgo: 2)])
        second.existing = []
        let impostor = ScriptedNoteSource("notes", items: [Fixtures.summary("notes", "x", secondsAgo: 3)])
        impostor.existing = []
        let nameless = ScriptedNoteSource("", items: [])
        let store = FakeOverlayStore(present: [
            Fixtures.overlay(1, key, layer: "notes", startedAt: Fixtures.epoch.addingTimeInterval(-1))
        ])
        let library = NoteLibrary(box: SourceBox([first, second, impostor, nameless]), store: store)
        let listing = await library.list(matching: nil, after: nil, limit: 10)
        #expect(ids(listing.rows) == ["meetings:a"])
        #expect(await library.activePluginIDs == ["meetings"])
        #expect(second.listCalls == 0 && impostor.listCalls == 0 && nameless.listCalls == 0)
        #expect(await library.sweep().isEmpty)
        #expect(second.existsCalls.isEmpty && impostor.existsCalls.isEmpty)
        #expect(store.detachCalls.isEmpty)
    }

    @Test("a changed set of sources starts the listing over and is read on refresh")
    func changingSet() async throws {
        let meetings = ScriptedNoteSource(
            "meetings", items: (0..<4).map { Fixtures.summary("meetings", "m\($0)", secondsAgo: Double($0)) })
        let box = SourceBox([meetings])
        let library = NoteLibrary(box: box)
        let first = await library.list(matching: nil, after: nil, limit: 2)
        let cursor = try #require(first.next)
        box.sources = [
            meetings,
            ScriptedNoteSource(
                "dictation", items: [Fixtures.summary("dictation", "s/1", secondsAgo: 0.5, kind: .dictation)]),
        ]
        // Still the old set until the library is told.
        #expect((await library.list(matching: nil, after: cursor, limit: 2)).restarted == false)
        await library.refreshSources()
        let again = await library.list(matching: nil, after: cursor, limit: 10)
        #expect(again.restarted)
        #expect(ids(again.rows) == ["meetings:m0", "dictation:s/1", "meetings:m1", "meetings:m2", "meetings:m3"])
        box.sources = []
        await library.refreshSources()
        let none = await library.list(matching: nil, after: nil, limit: 10)
        #expect(none.rows.isEmpty)
    }

    @Test("the change stream yields when the set of sources changes and when a source says so")
    func changeStream() async throws {
        let meetings = ScriptedNoteSource("meetings")
        let box = SourceBox([])
        let library = NoteLibrary(box: box)
        let (setChanges, trigger) = AsyncStream.makeStream(of: Void.self)
        var iterator = library.changes(sourceSetChanges: setChanges).makeAsyncIterator()
        box.sources = [meetings]
        trigger.yield()
        await iterator.next()
        #expect(await library.activePluginIDs == ["meetings"])
        await meetings.waitForChangeStream()
        meetings.signalChange()
        await iterator.next()
        trigger.finish()
        #expect(await iterator.next() == nil)
    }
}

@Suite("NoteLibrary: overlays")
struct NoteLibraryOverlayTests {
    @Test("an overlay for the same recording is merged into the row, with its layers")
    func merged() async throws {
        let key = Fixtures.key("meetings", "a")
        let started = Fixtures.epoch.addingTimeInterval(-10)
        let store = FakeOverlayStore(present: [
            Fixtures.overlay(2, key, layer: "transcript", startedAt: started),
            Fixtures.overlay(1, key, layer: "notes", startedAt: started),
        ])
        let source = ScriptedNoteSource("meetings", items: [Fixtures.summary("meetings", "a", secondsAgo: 10)])
        let listing = await NoteLibrary(box: SourceBox([source]), store: store).list(
            matching: nil, after: nil, limit: 5)
        #expect(listing.rows.count == 1)
        #expect(listing.rows[0].overlays.map(\.layer) == ["notes", "transcript"])
        #expect(store.detachCalls.isEmpty)
    }

    @Test(
        "an overlay written against another start is detached before the row is shown, and a detached row is listed once"
    )
    func recreatedKey() async throws {
        let key = Fixtures.key("meetings", "a")
        let old = Fixtures.epoch.addingTimeInterval(-5_000)
        let store = FakeOverlayStore(present: [
            Fixtures.overlay(1, key, layer: "notes", startedAt: old),
            Fixtures.overlay(2, key, layer: "transcript", startedAt: old),
        ])
        let source = ScriptedNoteSource("meetings", items: [Fixtures.summary("meetings", "a", secondsAgo: 10)])
        let listing = await NoteLibrary(box: SourceBox([source]), store: store).list(
            matching: nil, after: nil, limit: 5)
        let started = NoteTime.milliseconds(Fixtures.epoch.addingTimeInterval(-10))
        #expect(store.detachCalls.count == 1)
        #expect(store.detachCalls.first?.key == key)
        #expect(store.detachCalls.first?.reason == .startedAtChanged(sourceStartedAtMs: started))
        let live = try #require(listing.rows.first { $0.id == .live(key) })
        #expect(live.overlays.isEmpty, "the old overlay is never merged into the new recording's row")
        let detached = listing.rows.filter { if case .detached = $0.id { true } else { false } }
        #expect(detached.count == 1, "both edited layers are one row")
        #expect(detached.first?.id == .detached(key, startedAtMs: NoteTime.milliseconds(old)))
        #expect(detached.first?.overlays.map(\.layer) == ["notes", "transcript"])
        #expect(detached.first?.badge == .recordingRemoved)
        #expect(listing.rows.count == 2)
        // The next listing finds nothing left to detach.
        _ = await NoteLibrary(box: SourceBox([source]), store: store).list(matching: nil, after: nil, limit: 5)
        #expect(store.detachCalls.count == 1)
    }

    @Test("a detached overlay is not merged by key with a source row that has the same key")
    func detachedNotMerged() async throws {
        let key = Fixtures.key("meetings", "a")
        let old = Fixtures.epoch.addingTimeInterval(-9_000)
        let store = FakeOverlayStore(detached: [Fixtures.overlay(1, key, layer: "notes", startedAt: old)])
        let source = ScriptedNoteSource("meetings", items: [Fixtures.summary("meetings", "a", secondsAgo: 10)])
        let listing = await NoteLibrary(box: SourceBox([source]), store: store).list(
            matching: nil, after: nil, limit: 5)
        #expect(listing.rows.map(\.id) == [.live(key), .detached(key, startedAtMs: NoteTime.milliseconds(old))])
        #expect(listing.rows[0].overlays.isEmpty)
        #expect(store.detachCalls.isEmpty)
    }

    @Test("a failing detacher leaves the old overlay unmerged and the listing intact")
    func detachFails() async throws {
        let key = Fixtures.key("meetings", "a")
        let store = FakeOverlayStore(present: [
            Fixtures.overlay(1, key, layer: "notes", startedAt: Fixtures.epoch.addingTimeInterval(-5_000))
        ])
        store.failDetach = true
        let source = ScriptedNoteSource("meetings", items: [Fixtures.summary("meetings", "a", secondsAgo: 10)])
        let listing = await NoteLibrary(box: SourceBox([source]), store: store).list(
            matching: nil, after: nil, limit: 5)
        #expect(listing.rows.count == 2)
        #expect(listing.rows[0].id == .live(key))
        #expect(listing.rows[0].overlays.isEmpty)
        // The stale overlay is shown as detached in memory, never as the live note's text.
        let old = NoteTime.milliseconds(Fixtures.epoch.addingTimeInterval(-5_000))
        #expect(listing.rows[1].id == .detached(key, startedAtMs: old))
        #expect(listing.rows[1].badge == .recordingRemoved)
    }

    @Test("a kept overlay of an off source is listed read-only with its badge, an unedited recording is not")
    func sourceOff() async throws {
        let kept = Fixtures.key("dictation", "s/1")
        let store = FakeOverlayStore(present: [
            Fixtures.overlay(1, kept, layer: "cleaned", startedAt: Fixtures.epoch.addingTimeInterval(-30)),
            Fixtures.overlay(
                2, Fixtures.key("dictation", "s/2"), layer: "cleaned", startedAt: Fixtures.epoch, kept: false),
        ])
        let meetings = ScriptedNoteSource("meetings", items: [Fixtures.summary("meetings", "a", secondsAgo: 1)])
        let listing = await NoteLibrary(box: SourceBox([meetings]), store: store).list(
            matching: nil, after: nil, limit: 5)
        #expect(ids(listing.rows) == ["meetings:a", "dictation:s/1"])
        #expect(listing.rows[1].badge == .sourceOff("dictation"))
        #expect(listing.rows[1].isReadOnly)
        #expect(store.detachCalls.isEmpty)
    }
}

@Suite("NoteLibrary: detach sweep")
struct NoteLibrarySweepTests {
    private func rig(existing: Set<NoteKey>?) -> (ScriptedNoteSource, FakeOverlayStore, NoteLibrary, [NoteKey]) {
        let keys = ["a", "b", "c"].map { Fixtures.key("meetings", $0) }
        let store = FakeOverlayStore(
            present: keys.enumerated().map {
                Fixtures.overlay(Int64($0.offset + 1), $0.element, layer: "notes", startedAt: Fixtures.epoch)
            })
        let source = ScriptedNoteSource("meetings")
        source.existing = existing
        return (source, store, NoteLibrary(box: SourceBox([source]), store: store), keys)
    }

    @Test("keys the open source does not return are detached, in one batch")
    func detaches() async throws {
        let (source, store, library, keys) = rig(existing: [Fixtures.key("meetings", "b")])
        let gone = await library.sweep()
        #expect(Set(gone) == [keys[0], keys[2]])
        #expect(source.existsCalls.count == 1)
        #expect(store.detachCalls.allSatisfy { $0.reason == .sourceGone })
    }

    @Test("a source that throws, one that is off and one that hangs detach nothing")
    func unknown() async throws {
        let (source, store, library, _) = rig(existing: [])
        source.existsBehavior = .throwsError
        #expect(await library.sweep().isEmpty)

        let off = NoteLibrary(box: SourceBox([]), store: store)
        #expect(await off.sweep().isEmpty)

        source.existsBehavior = .hangs
        let clock = ManualClock()
        let slow = NoteLibrary(box: SourceBox([source]), store: store, clock: clock)
        let task = Task { await slow.sweep() }
        await clock.waitForSleeps(1)
        clock.advance(by: .milliseconds(150))
        #expect(await task.value.isEmpty)
        #expect(store.detachCalls.isEmpty)
    }
}

@Suite("NoteGrouping")
struct NoteGroupingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func row(_ plugin: PluginID, _ id: String, _ date: Date) -> NoteRow {
        let summary = NoteSummary(id: Fixtures.key(plugin, id), kind: .meeting, startedAt: date)
        return NoteRow(id: .live(summary.id), summary: summary, badge: nil, overlays: [], isReadOnly: false)
    }

    @Test("by time: calendar days, newest first, empty groups left out")
    func byTime() throws {
        // 2026-11-06 12:00 UTC
        let now = Date(timeIntervalSince1970: 1_793_966_400)
        let day = 86_400.0
        let rows = [
            row("meetings", "today-early", now.addingTimeInterval(-11.5 * 3600)),  // 00:30 today
            row("meetings", "yesterday", now.addingTimeInterval(-day)),
            row("dictation", "week", now.addingTimeInterval(-5 * day)),
            row("notes", "month", now.addingTimeInterval(-20 * day)),
            row("meetings", "old", now.addingTimeInterval(-90 * day)),
            row("meetings", "today-late", now.addingTimeInterval(-60)),
        ]
        let groups = NoteGroupingRules.group(rows, by: .time, now: now, calendar: calendar)
        #expect(groups.map(\.key) == [.today, .yesterday, .previousSevenDays, .previousThirtyDays, .earlier])
        #expect(groups[0].rows.map { $0.id.key.id } == ["today-late", "today-early"])
        let sparse = NoteGroupingRules.group([rows[1]], by: .time, now: now, calendar: calendar)
        #expect(sparse.map(\.key) == [.yesterday])
    }

    @Test("a note from 23:59 yesterday is yesterday at 00:05 today")
    func midnight() {
        let now = Date(timeIntervalSince1970: 1_793_923_500)  // 2026-11-06 00:05 UTC
        let late = now.addingTimeInterval(-6 * 60)
        #expect(NoteGroupingRules.timeKey(late, now: now, calendar: calendar) == .yesterday)
        #expect(NoteGroupingRules.timeKey(now.addingTimeInterval(3600), now: now, calendar: calendar) == .today)
    }

    @Test("by source: by plugin in a fixed order, other plugins after, newest first inside")
    func bySource() {
        let now = Date(timeIntervalSince1970: 1_793_966_400)
        let rows = [
            row("notes", "n", now), row("zeta", "z", now), row("dictation", "d", now),
            row("meetings", "m1", now.addingTimeInterval(-10)), row("meetings", "m2", now), row("alpha", "a", now),
        ]
        let groups = NoteGroupingRules.group(rows, by: .source, now: now, calendar: calendar)
        #expect(
            groups.map(\.key) == [
                .source("meetings"), .source("dictation"), .source("notes"), .source("alpha"), .source("zeta"),
            ])
        #expect(groups[0].rows.map { $0.id.key.id } == ["m2", "m1"])
    }
}
