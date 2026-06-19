#!/usr/bin/env bash
# Phase 6 driver (run on the HOST). Builds the image, runs the thin end-to-end
# inner loop (red -> green). Auth is passed THROUGH from the host env (never
# written to a file or baked into the image): export the token first.
#
#   1. one-time, in a normal terminal:   claude setup-token   # -> prints a token
#   2. export CLAUDE_CODE_OAUTH_TOKEN=<that token>
#   3. ./scripts/04_phase6.sh
set -euo pipefail
cd "$(dirname "$0")/.."   # -> prototype/

: "${CLAUDE_CODE_OAUTH_TOKEN:?Set CLAUDE_CODE_OAUTH_TOKEN first (run: claude setup-token). Or export ANTHROPIC_API_KEY and edit the -e line below.}"

docker build -t godot-proto .
mkdir -p proof
docker run --rm \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -v "$PWD/proof:/proof" \
  godot-proto /scripts/60_proof_e2e.sh "${1:-opengl3}"

echo "[*] Done. The verdict is in prototype/proof/result.txt"
echo "    red->green proof : gut.before.xml (failures=1) -> gut.after.xml (failures=0)"
echo "    change on disk   : main.diff, main.after.tscn"
echo "    rendered proof   : phase6_editor_${1:-opengl3}.png, game_shot.png, run.mp4"
