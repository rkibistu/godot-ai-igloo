#!/usr/bin/env bash
# Phase 3 driver (run on the HOST). Builds the image (cheap if cached) and runs
# the MCP bring-up test. The container keeps its default network so the plugin's
# `uvx` can fetch the godot-ai server + the probe can fetch `mcp` from PyPI.
# Probes run INSIDE the container, so no -p port mapping is needed.
set -euo pipefail
cd "$(dirname "$0")/.."   # -> prototype/

docker build -t godot-proto .
mkdir -p proof
docker run --rm -v "$PWD/proof:/proof" godot-proto /scripts/30_mcp_up.sh "${1:-opengl3}"

echo "[*] Done. Inspect prototype/proof/phase3_tools.txt, phase3_editor_${1:-opengl3}.png, editor.log"
