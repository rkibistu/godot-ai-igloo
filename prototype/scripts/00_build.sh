#!/usr/bin/env bash
# Phase 0/1 driver (run on the HOST). Builds the image and runs the render test,
# binding ./proof out so the screenshot + logs survive the container.
set -euo pipefail
cd "$(dirname "$0")/.."   # -> prototype/

docker build -t godot-proto .
mkdir -p proof
docker run --rm -v "$PWD/proof:/proof" godot-proto /scripts/10_editor_render.sh "${1:-opengl3}"

echo "[*] Done. Inspect prototype/proof/phase1_editor_${1:-opengl3}.png and prototype/proof/editor.log"
