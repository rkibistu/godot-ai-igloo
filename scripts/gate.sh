#!/usr/bin/env bash
# The done-gate (ADR-0003): 4 objective clauses, decided ENTIRELY by this script
# from exit codes + log greps. Zero LLM. Run INSIDE the container:
#   bash /scripts/gate.sh <issue-number>
# Exit 0 = PASS, 1 = FAIL.
set -uo pipefail
ISSUE="${1:-0}"
PROJ="${PROJECT_DIR:-/project}"   # agent_run points this at the cloned repo's game/ subdir;
                                  # Phase-1 callers bind-mount game/ -> /project and keep the default.

# Phase 7: the gate LOGIC is global; the project-specific values come from .igloo.yml (read by
# both this gate AND the agent prompt-builder, so they cannot drift). agent_run exports
# IGLOO_CONFIG=/project/.igloo.yml; standalone callers with no .igloo.yml get the literal defaults.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/config.sh"
TEST_CMD="$(cfg_get .test_command 'dotnet test')"
SCENE_REL="$(cfg_subst "$(cfg_get .issue_scene.scene 'test/scenes/issue_{n}.tscn')" "$ISSUE")"
SCENE_RES="res://$SCENE_REL"
SCENE_FILE="${PROJ}/$SCENE_REL"
GATE_PROOF="$(cfg_get .gate.proof true)"
# Extra-clause hook paths are relative to the REPO root (the dir holding .igloo.yml), not the game dir.
REPO_ROOT="$(dirname "${IGLOO_CONFIG:-$PROJ/.igloo.yml}")"
P="${PROOF_DIR:-/proof}"   # agent_run points this at the per-run dir; Phase-1 callers keep /proof
mkdir -p "$P"
export DISPLAY=:99
XVFB_PID=0
# Guard the kill: XVFB_PID is 0 until clause 2/4 starts Xvfb, and `kill -9 0` signals the
# whole PROCESS GROUP — which nukes a parent (agent_run.sh) when the gate fails early.
fail(){ echo "GATE #$ISSUE: FAIL — $1"; [ "${XVFB_PID:-0}" -gt 0 ] && kill -9 "$XVFB_PID" 2>/dev/null; exit 1; }

echo "== clause 1: Issue scene exists =="
[ -f "$SCENE_FILE" ] || fail "missing $SCENE_RES"
echo "  ok: $SCENE_RES present"

echo "== clause 3: full test suite ($TEST_CMD) =="
( cd "$PROJ" && eval "$TEST_CMD" >"$P/tests_${ISSUE}.log" 2>&1 ); TRC=$?
grep -E "Passed!|Failed!|error" "$P/tests_${ISSUE}.log" | tail -2
[ "$TRC" -eq 0 ] || fail "test suite rc=$TRC (see proof/tests_${ISSUE}.log)"
echo "  ok: suite passed"

echo "== build assembly for the runtime scene run =="
( cd "$PROJ" && dotnet build --nologo -v quiet >"$P/build_${ISSUE}.log" 2>&1 ) || fail "dotnet build failed"
godot --headless --path "$PROJ" --import >"$P/import_${ISSUE}.log" 2>&1 || true

echo "== clause 2 + 4: Issue scene boots clean + proof video =="
Xvfb :99 -screen 0 1152x648x24 >"$P/xvfb_${ISSUE}.log" 2>&1 &
XVFB_PID=$!
sleep 2
ffmpeg -y -f x11grab -video_size 1152x648 -framerate 20 -i :99 -t 8 \
    "$P/issue_${ISSUE}.mp4" >"$P/ffmpeg_${ISSUE}.log" 2>&1 &
FFPID=$!
sleep 1
LIBGL_ALWAYS_SOFTWARE=1 godot --path "$PROJ" --rendering-driver opengl3 --audio-driver Dummy "$SCENE_RES" \
    >"$P/run_${ISSUE}.log" 2>&1 &
GPID=$!
sleep 3
ffmpeg -y -f x11grab -video_size 1152x648 -i :99 -frames:v 1 "$P/issue_${ISSUE}.png" >/dev/null 2>&1 || true
wait "$GPID"; RRC=$?
wait "$FFPID" 2>/dev/null
kill -9 "$XVFB_PID" 2>/dev/null; XVFB_PID=0
echo "  scene run rc=$RRC"; tail -4 "$P/run_${ISSUE}.log"
grep -qE "SCRIPT ERROR|Parse Error|Unhandled exception|Failed to instantiate|Failed to load" "$P/run_${ISSUE}.log" \
    && fail "runtime errors in scene (see proof/run_${ISSUE}.log)"
[ "$RRC" -eq 0 ] || fail "scene exited non-zero (rc=$RRC)"
if [ "$GATE_PROOF" = "true" ]; then
  [ -s "$P/issue_${ISSUE}.mp4" ] || fail "no proof video produced"
  echo "  ok: booted clean; video $(stat -c%s "$P/issue_${ISSUE}.mp4") bytes, still issue_${ISSUE}.png"
else
  echo "  ok: booted clean (gate.proof=false — proof video not required)"
fi

# clause 5 (optional): project-declared extra clauses, each run as `bash <repo-relative> <issue#>`.
# A nonzero exit fails the gate — this is the ONLY per-project extension point (logic stays global).
while IFS= read -r hook; do
  [ -n "$hook" ] || continue
  echo "== extra clause: $hook =="
  [ -f "$REPO_ROOT/$hook" ] || fail "extra clause not found: $hook"
  ( cd "$REPO_ROOT" && bash "$hook" "$ISSUE" ) || fail "extra clause failed: $hook"
  echo "  ok: $hook"
done < <(cfg_list .gate.extra_clauses)

echo "GATE #$ISSUE: PASS"
