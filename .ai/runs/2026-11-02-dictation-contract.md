# Execution plan: Dictation contract (spec step 1.1)

Source doc: .ai/specs/2026-11-01-voice-dictation.md
Branch: feat/dictation-contract (base: main)

## Goal

Ship step 1.1 of the voice dictation spec, the additive `PounceKit` contract and its shell
implementations, as its own `risk-high` PR (`BACKWARD_COMPATIBILITY.md` section 1). No dictation plugin yet.

## Scope

- `PounceKit`: `Permission.microphone`; `KeyPhase` and `PluginCommand.onKeyEvent`; `EscapeKeyClaim` and
  `PluginContext.claimEscapeKey`; `PasteboardRepresentation.transientMarkerType` and `markerTypes`. Every
  addition has a default.
- `PounceApp`: microphone in `SystemPermissionsReader`, the Permissions pane (URL, symbol, texts);
  `HotkeyRegistrar` key-event handler (one down/up stream) and temporary Esc claim (Carbon hotkey);
  synchronous phase delivery and panel hiding before `.down` in `AppCoordinator`; `showPendingSteps()`
  after a plugin is enabled.
- `ClipboardPlugin`: `CaptureFilter` uses the shared marker constants, behaviour unchanged.
- Tests as listed in spec step 1.1; `en` + `pl` strings; `AGENTS.md` and `BACKWARD_COMPATIBILITY.md` notes.

## Non-goals

- Anything from step 1.2 on (plugin target, FluidAudio, Info.plist, entitlements).

## Risks

- A wrong event order or a stuck Esc claim would break global shortcuts; covered by ordered-stream and
  release tests, plus manual QA of shortcuts and Esc.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Contract

- [x] 1.1 Kontrakt (PounceKit additions, shell implementations, tests) — 2b1cc0e
