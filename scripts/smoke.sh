#!/usr/bin/env bash
# Foundation smoke test — run INSIDE the container. Verifies the three things
# Phase 1 proved: the Godot mono editor renders under Xvfb (software GL), and
# gdUnit4 C# tests run headless via dotnet test.
#
# From the repo root on the host:
#   docker run --rm \
#     -v "$PWD/game:/project" -v "$PWD/scripts:/scripts" -v "$PWD/proof:/proof" \
#     godot-ai-igloo:dev bash /scripts/smoke.sh
set -uo pipefail
export DISPLAY=:99
mkdir -p /proof

echo "=== versions ==="
godot --headless --version
echo "dotnet $(dotnet --version)"

echo
echo "=== render check: mono editor under Xvfb (llvmpipe) ==="
Xvfb :99 -screen 0 1600x900x24 >/proof/xvfb.log 2>&1 &
sleep 2
timeout 150 godot --headless --path /project --import >/proof/import.log 2>&1 || true
LIBGL_ALWAYS_SOFTWARE=1 godot --editor --path /project --rendering-driver opengl3 --verbose \
    >/proof/editor.log 2>&1 &
EDPID=$!
sleep 25
kill -0 "$EDPID" 2>/dev/null && echo "editor_alive=yes" || echo "editor_alive=NO"
ffmpeg -y -f x11grab -video_size 1600x900 -i :99 -frames:v 1 /proof/smoke_render.png \
    >/proof/ffmpeg.log 2>&1
kill "$EDPID" 2>/dev/null
grep -m1 -iE "llvmpipe|OpenGL API" /proof/editor.log || true
ls -la /proof/smoke_render.png 2>/dev/null || echo "NO SCREENSHOT"

echo
echo "=== gdUnit4 C# run-tests (dotnet test) ==="
( cd /project && dotnet test --nologo 2>&1 | tail -6; echo "TEST_EXIT=${PIPESTATUS[0]}" )

echo
echo "=== smoke done — open proof/smoke_render.png to eyeball the editor ==="
