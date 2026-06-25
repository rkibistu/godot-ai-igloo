#!/usr/bin/env bash
# Build the foundation image, TAGGED BY godot_version (Phase 7: godot-ai-igloo:<godot_version>).
# Multi-version is additive — bumping Godot builds a new tag; old games keep theirs. Build context
# is the repo root. `igloo build` calls this with GODOT_VERSION from the project's .igloo.yml.
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT_VERSION="${GODOT_VERSION:-4.6.3-stable}"
TAG="godot-ai-igloo:${GODOT_VERSION}"
docker build -f docker/Dockerfile --build-arg "GODOT_VERSION=${GODOT_VERSION}" -t "$TAG" .
docker tag "$TAG" godot-ai-igloo:dev   # back-compat alias for direct/legacy invocations
echo "built $TAG (+ :dev alias)"
