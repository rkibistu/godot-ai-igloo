#!/usr/bin/env bash
# Phase 4 driver (run on the HOST). Builds the image and runs the Claude-drives-
# the-editor test. Auth is passed THROUGH from the host env (never written to a
# file or baked into the image): export CLAUDE_CODE_OAUTH_TOKEN first.
#
#   1. one-time, in a normal terminal:   claude setup-token   # -> prints a token
#   2. export CLAUDE_CODE_OAUTH_TOKEN=<that token>
#   3. ./scripts/02_phase4.sh
set -euo pipefail
cd "$(dirname "$0")/.."   # -> prototype/

: "${CLAUDE_CODE_OAUTH_TOKEN:?Set CLAUDE_CODE_OAUTH_TOKEN first (run: claude setup-token). Or export ANTHROPIC_API_KEY and edit the -e line below.}"

docker build -t godot-proto .
mkdir -p proof
docker run --rm \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -v "$PWD/proof:/proof" \
  godot-proto /scripts/40_claude_drive.sh "${1:-opengl3}"

echo "[*] Done. Inspect prototype/proof/main.diff, main.after.tscn, claude_output.log, phase4_editor_${1:-opengl3}.png"
