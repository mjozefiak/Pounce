# LintelProviders: core without wiring (PR 2 of external AI providers)

Source doc: `.ai/specs/2026-11-10-external-ai-providers.md` (steps 1.1 to 1.6), ADR `docs/decisions/0011-external-providers.md`.

## Goal
A new SwiftPM target `LintelProviders` that can run the Claude Code CLI as an isolated child process behind a consent
check. Nothing in the app calls it: no behaviour or look changes.

## Scope
Target and test target, `ProviderDescriptor`, `ProviderLocator`, `ProviderProcess`, `ProviderGate`, `ProviderRunner`
with authorization, `ProviderSystem.quiet`, log scan. AGENTS.md. Non-goals: wiring to `MeetingsPlugin`, settings, UI,
migration, API key, `isolationVerified = true`. TSan step in `ci.yml` is added after #149 is merged (agreed with test-health).

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Core

- [x] 1.1 Target skeleton, descriptor, locator, process, gate, runner, quiet system
- [x] 1.2 Tests: descriptor, locator, process (fake binary), matrix rows, gate, source scans
- [x] 1.3 AGENTS.md and format
- [ ] 1.4 TSan step in ci.yml after #149

## Risks
`risk-high`: new subprocess boundary and consent enforcement. Mitigated by `isolationVerified = false` on the shipped descriptor and no caller.
