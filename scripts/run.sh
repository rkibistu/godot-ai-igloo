#!/usr/bin/env bash
# Host wrapper: run a command in a fresh --rm container with the bot's secrets injected
# via `docker run -e` (never baked). This is the secret-injection seam that Phase 3's
# `agent-run` will wrap. Generic on purpose: no game/ mount, no agent.
#
#   bash scripts/run.sh bash -c 'source /scripts/bot_init.sh && gh api user'
#
# Reads secrets from a gitignored `.env` at the repo root (see .env.example). Translates
# host BOT_GH_TOKEN -> container GH_TOKEN so it never collides with the host's own gh
# session, and so `gh`/git inside the container authenticate as the bot.
set -euo pipefail
IMG=godot-ai-igloo:dev
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -f .env ] || { echo "run: missing .env (copy .env.example and fill BOT_GH_TOKEN)" >&2; exit 1; }
set -a; . ./.env; set +a
[ -n "${BOT_GH_TOKEN:-}" ] || { echo "run: BOT_GH_TOKEN unset in .env" >&2; exit 1; }
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || echo "run: note — CLAUDE_CODE_OAUTH_TOKEN empty (only needed from Phase 4)" >&2

exec docker run --rm \
  -e GH_TOKEN="$BOT_GH_TOKEN" \
  -e CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
  -e IS_SANDBOX=1 \
  -v "$ROOT/scripts:/scripts" \
  "$IMG" "$@"
