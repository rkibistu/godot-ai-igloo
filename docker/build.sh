#!/usr/bin/env bash
# Build the foundation image. Build context is the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -f docker/Dockerfile -t godot-ai-igloo:dev .
