#!/usr/bin/env bash
# The done-gate (ADR-0003): 4 objective clauses, decided ENTIRELY by this script
# from exit codes + log greps. Zero LLM. Run INSIDE the container:
#   bash /scripts/gate.sh <issue-number>
# Exit 0 = PASS, 1 = FAIL.
set -uo pipefail
ISSUE="${1:-0}"
PROJ="${PROJECT_DIR:-/project}"   # agent_run points this at the cloned repo's game/ subdir;
                                  # Phase-1 callers bind-mount game/ -> /project and keep the default.
SCENE_RES="res://test/scenes/issue_${ISSUE}.tscn"
SCENE_FILE="${PROJ}/test/scenes/issue_${ISSUE}.tscn"
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

echo "== clause 3: full test suite (gdUnit4 via dotnet test) =="
( cd "$PROJ" && dotnet test --nologo >"$P/tests_${ISSUE}.log" 2>&1 ); TRC=$?
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
[ -s "$P/issue_${ISSUE}.mp4" ] || fail "no proof video produced"
echo "  ok: booted clean; video $(stat -c%s "$P/issue_${ISSUE}.mp4") bytes, still issue_${ISSUE}.png"

echo "GATE #$ISSUE: PASS"
