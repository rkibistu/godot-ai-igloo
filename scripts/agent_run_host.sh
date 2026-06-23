#!/usr/bin/env bash
# Host launcher for one autonomous run: `agent-run <issue#>`. Specializes the generic
# scripts/run.sh seam for the state-machine entrypoint — injects the bot secret via
# `docker run -e` (BOT_GH_TOKEN -> container GH_TOKEN, never baked) and mounts the
# per-run log dir so logs survive the --rm container.
#
#   bash scripts/agent_run_host.sh <issue-number>
#
# In Phase 3 the agent is stubbed (AGENT_CMD defaults to /scripts/agent_stub.sh inside
# agent_run.sh). Phase 4 will export a real AGENT_CMD here.
set -euo pipefail
IMG=godot-ai-igloo:dev
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ISSUE="${1:-}"
case "$ISSUE" in ''|*[!0-9]*) echo "usage: bash scripts/agent_run_host.sh <issue-number>" >&2; exit 64;; esac

[ -f .env ] || { echo "agent-run: missing .env (copy .env.example and fill BOT_GH_TOKEN)" >&2; exit 1; }
set -a; . ./.env; set +a
[ -n "${BOT_GH_TOKEN:-}" ] || { echo "agent-run: BOT_GH_TOKEN unset in .env" >&2; exit 1; }

mkdir -p "$ROOT/runs"

exec docker run --rm -i \
  -e GH_TOKEN="$BOT_GH_TOKEN" \
  -e CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
  -e IS_SANDBOX=1 \
  -e AGENT_RUN_ASSUME_READY="${AGENT_RUN_ASSUME_READY:-}" \
  -e AGENT_TIMEOUT="${AGENT_TIMEOUT:-}" \
  -v "$ROOT/scripts:/scripts" \
  -v "$ROOT/runs:/runs" \
  "$IMG" bash /scripts/agent_run.sh "$ISSUE"
