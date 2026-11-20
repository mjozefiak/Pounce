# Meeting capture counters (observability for #135)

Refs #135 (does not close it).

## Goal
Make the loss of remote speech measurable: per meeting and per channel (mic / system) counters of what the
recording pipeline drops, cuts, skips or fills with silence. Measurement only: nothing that reaches the
transcript changes.

## Scope
- `CaptureCounters` / `ChannelCounters` (pure value types, numbers only) filled by `MeetingSession` (actor, outside any
  audio callback) and by `SystemAudioSource` (its own `Mutex`, same worker queue as before; `TapRing.dropped` is the
  existing atomic, read only on snapshot).
- Counters: VAD segments opened/closed, unmatched speech ends, zero-length ranges, segments under 500 ms, hard cuts at the
  segment limit, segments/seconds sent to the engine against seconds recorded, empty engine results, deferred
  (no model) / `.spool` / failed results, replay results, track interruptions/resumes/losses, silence inserted on resume,
  system: tap recreations/failures, format changes, timeline resyncs, silence inserted by the pipeline, ring drops.
- Log (category `meetings`) at the end of the meeting: numbers only.
- Persisted as numbers in `Plugins/meetings/capture-counters.json` (last 20 meetings, atomic, 0600): no schema change.
- Settings -> Meetings -> Advanced: "Copy diagnostics" (same plain-text style as Window Management's).
- `audio_gap` written live (column already exists) when silence was inserted into a track or buffers were dropped.
  Seconds of gap would need a new column: follow-up, no migration here.

## Non-goals
Pre-roll, VAD thresholds, hard-cut placement, second pass (experiments 2-5 of #135), `Sources/MeetingsPlugin/Notes/`,
migrations, workflows. VAD-internal rejections are not observable through `VoiceActivityDetector` (documented).

## Risks
Audio path: no allocation or lock added to the IO callback (nothing touched there). Privacy: counters hold no text,
names, titles or device names (a test scans the report).

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Counters

- [x] 1.1 Counter types and report formatter
- [x] 1.2 System source / tap ring statistics
- [x] 1.3 Session counting, live audio_gap, log

### Phase 2: Surfacing

- [x] 2.1 Persistence and Copy diagnostics in the pane
- [ ] 2.2 Docs and QA

### Phase 3: Review fixes

- [x] 3.1 End padding of a stopped system tap is not a hole (no `audio_gap` on every meeting)
- [x] 3.2 Counters of a meeting discarded as quiet are saved; counters saved while the meeting is still `processing`
- [x] 3.3 Every meeting delete prunes its counters; one lock for every store instance
- [x] 3.4 Tests for empty ranges, unmatched ends, forced closes, `.spool`, an unloadable model, end padding, a failed recreation, the delete paths and pinned segmentation; follow-ups #145 (gap length) and #146 (VAD rejections)
