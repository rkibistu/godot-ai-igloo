#!/usr/bin/env bash
# Host launcher for one autonomous run: `agent-run <issue#>` (wrapped by `igloo run`). Injects
# the bot secret via `docker run -e` (BOT_GH_TOKEN -> container GH_TOKEN, never baked) and mounts
# the per-run log dir so logs survive the --rm container.
#
#   bash scripts/agent_run_host.sh <issue-number>
#
# Phase 7: harness code and the GAME repo are separate. HARNESS_HOME holds scripts/fixture/addon;
# the game repo (PROJECT_DIR) supplies the committed .igloo.yml. The dispatcher sets both; run
# directly (no env) and it self-targets the bundled fixture, exactly as before. PRE-CLONE facts —
# the image tag (godot_version) and the target repo slug — are resolved here from .igloo.yml;
# post-clone facts are read inside the container from the committed file.
#
# Production runs use the real agent (AGENT_CMD defaults to /scripts/agent_real.sh: claude -p +
# editor/MCP). A fake AGENT_CMD keeps proofs credit-free.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"            # the harness repo (scripts live here)
HARNESS_HOME="${IGLOO_HARNESS_HOME:-$ROOT}"
PROJECT_DIR="${IGLOO_PROJECT_DIR:-$HARNESS_HOME}"   # the game repo; self = the bundled fixture

ISSUE="${1:-}"
case "$ISSUE" in ''|*[!0-9]*) echo "usage: bash scripts/agent_run_host.sh <issue-number>" >&2; exit 64;; esac

# Global secrets (Phase 7: ~/.igloo/.env; defaults to the harness repo .env for self-target).
ENV_FILE="${IGLOO_ENV:-$HARNESS_HOME/.env}"
[ -f "$ENV_FILE" ] || { echo "agent-run: missing $ENV_FILE (copy .env.example and fill BOT_GH_TOKEN)" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
[ -n "${BOT_GH_TOKEN:-}" ] || { echo "agent-run: BOT_GH_TOKEN unset in $ENV_FILE" >&2; exit 1; }

# Per-game host-side config: image tag + target repo are needed BEFORE the container clones.
export IGLOO_CONFIG_START="$PROJECT_DIR"; unset IGLOO_CONFIG
# shellcheck disable=SC1091
source "$HARNESS_HOME/scripts/lib/config.sh"
GODOT_VERSION="$(cfg_get .godot_version 4.6.3-stable)"
IMG="${IGLOO_IMG:-godot-ai-igloo:$GODOT_VERSION}"
REPO="$(cfg_get .repo)"
case "$REPO" in ''|__detect__)
  REPO="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null \
          | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##')" ;;
esac
[ -n "$REPO" ] || { echo "agent-run: could not resolve target repo (set 'repo:' in $PROJECT_DIR/.igloo.yml)" >&2; exit 1; }

# Per-game run logs live INSIDE the game repo (gitignored .igloo/runs/), not in the harness clone.
# Self-target (PROJECT_DIR == HARNESS_HOME) keeps them under the fixture, exactly as before.
LOGS_DIR="$PROJECT_DIR/.igloo/runs"
mkdir -p "$LOGS_DIR"
echo "agent-run: logs -> $LOGS_DIR/$ISSUE/<timestamp>/  (run.log, gate.log, proof/issue_$ISSUE.mp4)"

exec docker run --rm -i \
  -e GH_TOKEN="$BOT_GH_TOKEN" \
  -e CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
  -e IS_SANDBOX=1 \
  -e IGLOO_REPO="$REPO" \
  -e AGENT_RUN_ASSUME_READY="${AGENT_RUN_ASSUME_READY:-}" \
  -e AGENT_TIMEOUT="${AGENT_TIMEOUT:-}" \
  -e AGENT_CMD="${AGENT_CMD:-/scripts/agent_real.sh}" \
  -v "$HARNESS_HOME/scripts:/scripts" \
  -v "$LOGS_DIR:/runs" \
  -v "$HARNESS_HOME/game/addons/godot_ai:/opt/godot_ai:ro" \
  "$IMG" bash /scripts/agent_run.sh "$ISSUE"
