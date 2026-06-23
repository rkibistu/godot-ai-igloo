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

Status (2026-06-23): **Phase 4b (minimal) complete — the real Claude agent runs end-to-end.**
A fresh run on a real issue produced a **Ready PR through the gate** (`#111`→PR `#112`):
`scripts/agent_run.sh` (+ host launcher `agent_run_host.sh`) classifies an issue (7-row
table), brings up the agent via the `AGENT_CMD` seam — production = `scripts/agent_real.sh`
(`claude -p` + Godot editor + `godot_ai` MCP, governing prompt `skills/fresh-implement.md`)
— runs the post-exit done-gate (`scripts/gate.sh`), and routes to a durable signal
(pass→Ready PR, timeout→Draft+`needs-rerun`, gate-red/block→Draft+`blocked`). Proofs pin
`AGENT_CMD` to a stub/fake so they stay credit-free (`phase3_proof.sh`, `phase4a_proof.sh`);
`scripts/agent_mcp_smoke.sh` is the credit-free MCP de-risk. The `godot_ai` addon is
gitignored → provisioned at runtime from a host mount `/opt/godot_ai`. **Next: Phase 4c/5**
— `fix-comments` skill + fix-run, throttle-signature capture, then review-setup. Dev image:
`godot-ai-igloo:dev` (built from `docker/`); game seed in `game/`; secrets via a gitignored
`.env` (template `.env.example`); bot `justfortest1234`, human reviewer `rkibistu`
(`CLAUDE_CODE_OAUTH_TOKEN` needed for real runs; `REVIEWER_GH_TOKEN` only for the Phase-3
proof's row-2 fix fixture).
