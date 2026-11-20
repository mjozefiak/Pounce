# Provider canary follow-up: --safe-mode, one positive control, TCC row

Source doc: `docs/decisions/0011-external-providers.md`, `.ai/specs/2026-11-10-external-ai-providers.md`.

## Goal

Close the owner's answers on the provider canary: measure `--safe-mode`, run one positive control on the real
configuration (counts only), and decouple `isolationVerified` from the TCC test.

## Scope

`scripts/provider-canary/` (script, tests, README), the ADR and the spec. No change to `Sources/`, no change to
`.github/workflows`, no app behaviour change (docs and a manual script; nothing calls it). Docs-only for the
validation gate: Swift is untouched.

## Non-goals

`Sources/LintelProviders` (PR #153 is open). No real data, paths from a home directory, hook names or configuration
content in the repository.

## Risks

The positive control runs the owner's real hooks once; it is behind an explicit flag, off by default, synthetic
prompt only, no session saved, config directory compared by name and time and never read or cleaned by the script.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Script

- [x] 1.1 `safeMode` step and the single `realConfig` pair replace the old two real-config calls
- [x] 1.2 Unit tests for the new pure helpers and the opt-in pair

### Phase 2: Measurements and docs

- [x] 2.1 Measure `--safe-mode` (two runs) and the real-config pair (one run), counts only
- [x] 2.2 ADR 0011, spec and README: results, golden list, TCC/FDA row, `isolationVerified` independent of TCC
