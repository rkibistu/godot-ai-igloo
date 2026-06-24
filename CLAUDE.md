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

Status (2026-06-24): **Phase 5 complete — the full inner loop runs end-to-end.** The sandbox
half (Phases 1–4c) has both brains: `fresh-implement` (4b) and `fix-comments` (4c); the human
half (Phase 5) is the host-side `review_setup.sh`. `scripts/agent_run.sh` (+ host launcher `agent_run_host.sh`) classifies an
issue (7-row table), prepares the branch, **provisions the gitignored `godot_ai` addon** so the
gate is robust for any agent, gathers the payload (fresh = issue body; **fix = a rich payload —
surgical header + issue background + per-thread diff_hunk + full conversation**), brings up the
agent via the `AGENT_CMD` seam — production = `scripts/agent_real.sh` (`claude -p` + Godot editor
+ `godot_ai` MCP; governing prompt chosen by class: `skills/fresh-implement.md` /
`skills/fix-comments.md`) — runs the post-exit done-gate (`scripts/gate.sh`), routes to a durable
signal (pass→Ready PR, timeout→Draft+`needs-rerun`, gate-red/block→Draft+`blocked`), and on a fix
run verifies every thread got a bot reply. **Phase 5 (review-setup, host):** `bash scripts/review_setup.sh <issue#>` makes an
isolated `git worktree` on `agent/issue-<n>`, provisions the gitignored `godot_ai` addon into it,
and opens the local Godot editor (`GODOT_BIN`/extracted zip) — then hands off. The human runs their
own AI session **as `rkibistu`** (the bot is local only because we're testing; in real use it lives
only in the container) and posts review comments in the GitHub UI; the bot's Fix run picks them up.
No LLM → credit-free; the editor-window launch is a manual eyeball. **Repo cleanup (2026-06-24):**
the credit-free proof suite (`phase{2,3,4a,4c,5}_proof.sh` + the `agent_stub`/`agent_fake`/`agent_fix_fake`
agents + `agent_mcp_smoke.sh` + Phase-1 `binary_proof.sh`/`smoke.sh`) and the dead `mcp_cs_*.sh`
were **removed** in a production-only strip — each was proven PASS at the time (see the build log).
**Restore from commit `fd72b70`** (`git checkout fd72b70 -- scripts/<name>.sh`) to re-run any
regression, e.g. before the Phase-7 refactor. **Next: Phase 6 (merge — likely just the GitHub squash-merge UI;
`Closes #n` auto-closes) → Phase 7 (harness extraction: `--repo` + `.igloo.yml`, the
decided-but-deferred "shared harness pointed at any repo" model).** Scope cuts still open:
throttle-signature detection **deferred**; the one paid `claude -p` fix acceptance run is the
**user's to fire** (`bash scripts/agent_run_host.sh <issue#>`). Dev image:
`godot-ai-igloo:dev` (built from `docker/`); game seed in `game/`; secrets via a gitignored
`.env` (template `.env.example`); bot `justfortest1234`, human reviewer `rkibistu`
(`CLAUDE_CODE_OAUTH_TOKEN` needed for real runs; `REVIEWER_GH_TOKEN` authors the non-bot review
threads in the Phase-3 row-2 and Phase-4c fix fixtures).
