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

Status (2026-06-22): **Phase 1 (C# inner loop + done-gate) complete; Phase 2 (bot
GitHub account + secrets injection) is next.** Dev image: `godot-ai-igloo:dev` (built
from `docker/`); game seed in `game/`; gate/proof scripts in `scripts/`.
