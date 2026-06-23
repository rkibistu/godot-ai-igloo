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

Status (2026-06-23): **Phase 4a (done-gate wiring + outcome routing, no LLM) complete;
Phase 4b (real Claude agent + governing skills + MCP + throttle) is next.** (Phase 4 was
split to land the deterministic routing before the costly LLM integration.) The entrypoint
`scripts/agent_run.sh` (+ host launcher `agent_run_host.sh`) classifies an issue against
the 7-row table, runs the post-exit done-gate (`scripts/gate.sh`), and routes every run to
a durable signal (pass→Ready PR, timeout→Draft+`needs-rerun`, gate-red/block→Draft+`blocked`).
The agent is stubbed via the `AGENT_CMD` seam (`agent_stub.sh`; `agent_fake.sh` drives the
4a proof). Proven by `scripts/phase4a_proof.sh` (+ `phase3_proof.sh`). Dev image:
`godot-ai-igloo:dev` (built from `docker/`); game seed in `game/`; gate/proof/bot-init/run
scripts in `scripts/`; runtime secrets injected via a gitignored `.env` (template:
`.env.example`) — bot account is `justfortest1234`, human reviewer `rkibistu`. Note: the
Phase-3 proof's row-2 (`fix`) live fixture needs `REVIEWER_GH_TOKEN` (rkibistu PAT) in
`.env` to author a non-bot review thread; without it that one row is skipped.
