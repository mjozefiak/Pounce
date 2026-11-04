# ADR 0006: Shared speech layer (`PounceSpeech`) and the `Models/` folder

- Status: accepted (owner approval given in advance in the spec's "Tryb realizacji", Q4, Q10, Q14)
- Date: 2026-11-03
- Spec: `.ai/specs/2026-11-03-meeting-notes.md`

## Context

`DictationPlugin` owns the speech stack (microphone capture, VAD, speech engines, `ModelManager`, the llama.cpp runtime). Meeting notes need the same stack. Plugins must not import each other.

## Options

1. A mode inside `DictationPlugin`: disabling dictation would disable meetings, and the plugin would grow a library, diarization and long sessions.
2. Copy the code: two `ModelManager`s (download code with SHA-256 and host allow list) and two `LlamaRuntime`s (a GGUF parser in process) to patch.
3. **A new target `PounceSpeech`** that both plugins import.

## Decision

- Option 3. `PounceSpeech` depends on no repository target and on no plugin. The dependency rule becomes plugins → `PounceSpeech` / `PouncePersistence` / `PounceCore` → `PounceKit`; plugins still never import each other or `PounceApp`.
- The code moves mechanically from `DictationPlugin` (types become `public`). Three changes while moving: a neutral `ChatMessage`, `LlamaRuntime(contextLength:)` defaulting to 4096, and an additive `generateResult(...)`. The VAD → engine loop stays copied in each session type (not unified now).
- **Models** move to `Application Support/Pounce/Models/{speech,llm}/` and are exposed as `PluginContext.modelsDirectory`. `ModelsMigration` in `PounceApp` renames `Plugins/dictation/Models` and `Plugins/dictation/llm` once at launch, before plugins activate; it is idempotent; if source and target are both non-empty nothing is merged or deleted. Erase Data no longer removes models.
- **Leases.** `SpeechEngineLease` (key: model id and folder) and `LLMLease` (key: model id and `contextLength`) are process singletons: at most one engine and one LLM resident; a key already leased is shared; another key while leased gets `busy`; `interactive` requests go before `background` ones and cancel running background generation between tokens.
- **One `ModelManager` per folder** (registry in `PounceSpeech`), because two instances over the same folder would corrupt `<id>.partial` and the remove-and-move step.

## Consequences

- Dictation behaves as before, except for Erase Data and the model path.
- Rolling back after the migration means downloading the models again (they are reproducible).
- `BACKWARD_COMPATIBILITY.md` §1–3 and `CODE_REVIEW.md` are updated in the same PR.
