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

Status (2026-06-24): **Phase 4c complete — the real fix loop (`fix-comments`) is built and
proven credit-free.** Both sandbox jobs now have a real brain: `fresh-implement` (4b) and
`fix-comments` (4c). `scripts/agent_run.sh` (+ host launcher `agent_run_host.sh`) classifies an
issue (7-row table), prepares the branch, **provisions the gitignored `godot_ai` addon** so the
gate is robust for any agent, gathers the payload (fresh = issue body; **fix = a rich payload —
surgical header + issue background + per-thread diff_hunk + full conversation**), brings up the
agent via the `AGENT_CMD` seam — production = `scripts/agent_real.sh` (`claude -p` + Godot editor
+ `godot_ai` MCP; governing prompt chosen by class: `skills/fresh-implement.md` /
`skills/fix-comments.md`) — runs the post-exit done-gate (`scripts/gate.sh`), routes to a durable
signal (pass→Ready PR, timeout→Draft+`needs-rerun`, gate-red/block→Draft+`blocked`), and on a fix
run verifies every thread got a bot reply. Proofs pin `AGENT_CMD` to a stub/fake so they stay
credit-free (`phase3_proof.sh` 7/7, `phase4a_proof.sh` 4/4, **`phase4c_proof.sh`** — skill-select
unit + a two-thread fix-loop → Ready); `scripts/agent_mcp_smoke.sh` is the credit-free MCP
de-risk. **Next: Phase 5 (review-setup)** — host, flag-driven (see `plan_implementation.md`).
Scope cuts still open: throttle-signature detection **deferred**; the one paid `claude -p`
acceptance run (real human thread → real agent fix + reply → Ready) is the **user's to fire**
(`bash scripts/agent_run_host.sh <issue#>`). Dev image:
`godot-ai-igloo:dev` (built from `docker/`); game seed in `game/`; secrets via a gitignored
`.env` (template `.env.example`); bot `justfortest1234`, human reviewer `rkibistu`
(`CLAUDE_CODE_OAUTH_TOKEN` needed for real runs; `REVIEWER_GH_TOKEN` authors the non-bot review
threads in the Phase-3 row-2 and Phase-4c fix fixtures).
