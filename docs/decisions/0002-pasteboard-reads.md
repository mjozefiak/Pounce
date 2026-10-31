# ADR 0002: Read the pasteboard on the main actor

- Status: accepted (spike 2.2 of the MVP spec)
- Date: 2026-10-31
- Spec: `.ai/specs/2026-10-31-pounce-launcher-mvp.md`, step 2.2 and the edge case "Schowek zmienił się
  ponownie w trakcie odczytu w tle"

## Context

The spec's `PasteboardWatcher` compares `NSPasteboard.changeCount` on the main actor every 0.5 s and
reads and hashes the new contents in the background, so a large entry (a 20 MB image) never blocks
the UI. Step 2.2 asks to verify that reading `NSPasteboard` off the main thread is safe; if it is
not, the read happens on `MainActor` and only hashing stays in the background.

## Spike

1. **Documentation.** Apple does not document `NSPasteboard` as thread-safe. It is not in the AppKit
   part of the Threading Programming Guide's thread-safety summary, and the class is not annotated
   `@MainActor` either. A 2026 report of `NSPasteboard` memory corruption while a file promise was
   handled says Apple told the developer that `NSPasteboard` is not safe to use outside the main
   thread: its internal type cache is mutated without a lock
   ([Michael Tsai, 2026-08-03](https://mjtsai.com/blog/2026/08/03/nspasteboard-crashes-when-handling-file-promises/)).
2. **Stress test** (macOS 27.0.1, a private `NSPasteboard(name:)`, never the general pasteboard): a
   background queue read `types`, `pasteboardItems` and their data 4,000 times while the main thread
   rewrote the pasteboard about 7,500 times. Three runs finished without a crash and without a torn
   read at a stable `changeCount`.
3. **Cost of the fallback.** Reading 1, 5 and 20 MB representations on the main thread took 1.0 ms,
   0.1 ms and 0.1 ms in-process. Data another app promised lazily is produced by that app during the
   read, so a cross-process read can take longer; the 20 MB limit bounds it.

A passing stress test cannot prove the absence of a data race in a closed-source class, and the
vendor's guidance is that the class is main-thread only. **The spike does not confirm the
background read, so Pounce uses the spec's fallback.**

## Decision

- `PasteboardClient` keeps every member `@MainActor`. `PasteboardWatcher` compares `changeCount`, reads
  the types, filters (marker types, ignored apps) and copies the representations on the main actor,
  and stops at 20 MB.
- After the read it compares `changeCount` again. If the pasteboard changed meanwhile, the copy is
  dropped and the next tick handles the newer contents.
- Everything after the copy runs off the main actor: classification (kind, preview text, image size),
  the HMAC `content_hash`, AES-GCM sealing of blobs and the database write.

## Consequences

- The spec's design holds; only the read moved to the main actor, as its fallback says. No spec
  amendment is needed beyond this record.
- A very large entry promised lazily by another app can cost the main thread a few milliseconds at
  capture time. If measurements later show hitches, the next step is to skip representations of
  types Pounce does not use before reading their data, not to read off the main thread.
- If Apple documents `NSPasteboard` as thread-safe, the read can move into the background task. The
  port change would be additive (a new, non-isolated read with a default), keeping
  `readContents(maxBytes:)` as it is.
