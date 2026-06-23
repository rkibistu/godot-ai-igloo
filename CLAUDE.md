## Agent skills

### Issue tracker

Issues are tracked as GitHub Issues in `rkibistu/godot-ai-igloo` via the `gh` CLI; external PRs are not pulled into triage. See `docs/agents/issue-tracker.md`.

### Triage labels

Uses the default label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Current build

`plan_implementation.md` is the authoritative phased build plan — **read it before
continuing implementation** (its build log records what's done). Design basis:
`CONTEXT.md` (glossary) + `docs/adr/0001`–`0003`.

Status (2026-06-23): **Phase 2 (bot identity + secrets injection) complete; Phase 3
(deterministic state-machine entrypoint, no LLM) is next.** Dev image:
`godot-ai-igloo:dev` (built from `docker/`); game seed in `game/`; gate/proof/bot-init
scripts in `scripts/`; runtime secrets injected via a gitignored `.env` (template:
`.env.example`) — bot account is `justfortest1234`, human reviewer `rkibistu`.
