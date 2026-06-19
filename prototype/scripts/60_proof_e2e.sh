#!/usr/bin/env bash
# Phase 6 — thin END-TO-END smoke: the concept's inner loop, once, cold.
# Demonstrates a REAL red -> green task:
#   1. inject an acceptance test ("main.tscn must have a Marker Node2D")   -> RED
#   2. Claude satisfies it via MCP (the proven Phase 4 action)
#   3. the SAME unchanged Phase 5 gate (50_gate.sh) re-judges              -> GREEN
# Verdict comes from files only: the gate flipped red->green AND the Marker is
# objectively on disk. Nothing Claude *says* is trusted.
#
# Run INSIDE the container. Needs CLAUDE_CODE_OAUTH_TOKEN (or ANTHROPIC_API_KEY)
# in the env (docker run -e ...). Arg 1 = rendering driver (default opengl3).
# Not `set -e`: we always want the diagnostics + verdict even when a step fails.
set -uo pipefail

DRIVER="${1:-opengl3}"
HTTP_PORT=8000
WS_PORT=9500
PROJECT=/project
SCENE=/project/scenes/main.tscn
ACCEPT_TEST=/project/test/test_acceptance.gd
mkdir -p /proof
echo "[*] Phase 6 — thin end-to-end (red -> green), driver=$DRIVER"

# 0. Auth + CLI sanity (same gate as Phase 4).
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "[FAIL] no CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY in env."
  echo "       Generate one with 'claude setup-token' and pass it: docker run -e CLAUDE_CODE_OAUTH_TOKEN ..."
  exit 2
fi
echo "[*] claude: $(command -v claude || echo MISSING)"

# 1. Inject the task's acceptance test into the EPHEMERAL container project.
#    Deliberately NOT committed (it would make Phase 5's clean run red). Models
#    "a task arrives": the objective is encoded as a machine-checkable test.
cat > "$ACCEPT_TEST" <<'GD'
extends GutTest

## INJECTED at runtime by Phase 6 (60_proof_e2e.sh) — NOT committed.
## The task's acceptance criterion: scenes/main.tscn must contain a child
## Node2D named "Marker". Starts RED; Claude must satisfy it via MCP.

func test_main_scene_has_marker_node() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	assert_not_null(packed, "main.tscn should load")
	if packed == null:
		return
	var root := packed.instantiate()
	var marker := root.get_node_or_null("Marker")
	assert_not_null(marker, "main.tscn must have a child node named 'Marker'")
	assert_true(marker is Node2D, "'Marker' must be a Node2D")
	root.free()
GD
echo "[*] Injected acceptance test -> $ACCEPT_TEST"

# 2. Xvfb (the editor needs a display; the gate runs headless and ignores it).
Xvfb :99 -screen 0 1280x800x24 -ac +extension GLX +render -noreset >/proof/xvfb.log 2>&1 &
XVFB_PID=$!
sleep 2
export DISPLAY=:99

echo "[*] Importing project (headless)..."
godot --headless --path "$PROJECT" --import >/proof/import.log 2>&1 || echo "[!] import nonzero (often OK)"

# 3. GATE BEFORE — reuse the REAL Phase 5 gate. Expect FAIL (acceptance is red).
echo "[*] ===== GATE BEFORE (expect FAIL: no Marker yet) ====="
/scripts/50_gate.sh clean
BEFORE_RC=$?
cp -f /proof/gut.clean.xml /proof/gut.before.xml 2>/dev/null || true
cp -f /proof/gut.clean.log /proof/gut.before.log 2>/dev/null || true
cp -f /proof/run.clean.log /proof/run.before.log 2>/dev/null || true
echo "[*] gate_before rc=$BEFORE_RC (want != 0)"

# 4. Enable plugin + bring up editor & MCP bridge (Phase 3/4 mechanics).
if ! grep -q "godot_ai/plugin.cfg" "$PROJECT/project.godot"; then
  cat >> "$PROJECT/project.godot" <<'EOF'

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_ai/plugin.cfg")
EOF
fi
echo "[*] Launching editor (--rendering-driver $DRIVER)..."
LIBGL_ALWAYS_SOFTWARE=1 godot --editor --path "$PROJECT" --rendering-driver "$DRIVER" --verbose \
    >/proof/editor.log 2>&1 &
EDITOR_PID=$!

echo "[*] Waiting for MCP bridge (:$HTTP_PORT + :$WS_PORT)..."
BRIDGE_UP=0; DEADLINE=$(( $(date +%s) + 150 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if ! kill -0 "$EDITOR_PID" 2>/dev/null; then echo "[!] editor died early"; break; fi
  if ss -ltn 2>/dev/null | grep -q ":$HTTP_PORT\b" && ss -ltn 2>/dev/null | grep -q ":$WS_PORT\b"; then
    BRIDGE_UP=1; echo "[+] bridge up"; break
  fi
  sleep 3
done
if [ "$BRIDGE_UP" != 1 ]; then
  echo "[FAIL] MCP bridge never came up — see /proof/editor.log"
  kill "$EDITOR_PID" "$XVFB_PID" 2>/dev/null; exit 1
fi

# 5. Snapshot, then let Claude do the task via MCP (the Phase 4 prompt verbatim).
cp "$SCENE" /proof/main.before.tscn
cat > /proof/mcp-config.json <<EOF
{ "mcpServers": { "godot": { "type": "http", "url": "http://127.0.0.1:$HTTP_PORT/mcp" } } }
EOF
cd "$PROJECT"
PROMPT='Use ONLY the "godot" MCP server tools (do not edit any files directly). Steps: (1) call session_activate, or session_manage with op="list" then activate the session, to attach to the running Godot editor; (2) create a child node of type Node2D named "Marker" under the root node of res://scenes/main.tscn using node_create; (3) persist it to disk with scene_save. Then report the resulting scene hierarchy.'
echo "[*] Running Claude headless to satisfy the acceptance test..."
# IS_SANDBOX=1: Claude refuses --dangerously-skip-permissions as root; the --rm
# container genuinely is a sandbox.
IS_SANDBOX=1 claude --dangerously-skip-permissions \
  --mcp-config /proof/mcp-config.json \
  -p "$PROMPT" >/proof/claude_output.log 2>&1
CLAUDE_RC=$?
echo "[*] claude exit=$CLAUDE_RC"; tail -n 20 /proof/claude_output.log

cp "$SCENE" /proof/main.after.tscn
echo "[*] ---- diff main.tscn (before -> after) ----"
diff -u /proof/main.before.tscn /proof/main.after.tscn | tee /proof/main.diff || true

# 6. Proof: editor screenshot (the editor rendered live while the agent worked).
import -window root "/proof/phase6_editor_${DRIVER}.png" 2>/proof/shot.log \
  || ffmpeg -y -f x11grab -video_size 1280x800 -i :99 -frames:v 1 "/proof/phase6_editor_${DRIVER}.png" >/proof/shot.log 2>&1

# 7. Tear down the editor before re-judging (avoid two godot procs on the project).
kill "$EDITOR_PID" 2>/dev/null
sleep 3

# 8. GATE AFTER — the SAME gate, now expect PASS (Marker present -> acceptance green).
echo "[*] ===== GATE AFTER (expect PASS: Marker added) ====="
/scripts/50_gate.sh clean
AFTER_RC=$?
cp -f /proof/gut.clean.xml /proof/gut.after.xml 2>/dev/null || true
cp -f /proof/gut.clean.log /proof/gut.after.log 2>/dev/null || true
cp -f /proof/run.clean.log /proof/run.after.log 2>/dev/null || true
echo "[*] gate_after rc=$AFTER_RC (want 0)"

# 9. Bonus proof: capture the running game window. Extend the self-quit FIRST so
#    the window stays up long enough to grab reliably (post-gate -> affects no verdict).
sed -i 's/create_timer(1.0)/create_timer(8.0)/' "$PROJECT/scripts/main.gd"
echo "[*] Capturing the running game window for proof..."
( ffmpeg -y -f x11grab -video_size 1280x800 -framerate 15 -i :99 -t 6 /proof/run.mp4 >/proof/capture.log 2>&1 ) &
FFMPEG_PID=$!
LIBGL_ALWAYS_SOFTWARE=1 godot --path "$PROJECT" "res://scenes/main.tscn" --rendering-driver "$DRIVER" \
    >/proof/game_run.log 2>&1 &
GAME_PID=$!
sleep 4
import -window root /proof/game_shot.png 2>>/proof/shot.log || true
wait "$FFMPEG_PID" 2>/dev/null
kill "$GAME_PID" 2>/dev/null
ffmpeg -y -ss 00:00:00.5 -i /proof/run.mp4 -frames:v 1 /proof/game_frame.png >>/proof/capture.log 2>&1 || true

# 10. Verdict — from files only.
MARKER_ON_DISK=no
grep -qE '\[node name="Marker" type="Node2D"' /proof/main.after.tscn && MARKER_ON_DISK=yes

VERDICT=FAIL
if [ "$BEFORE_RC" -ne 0 ] && [ "$AFTER_RC" -eq 0 ] && [ "$MARKER_ON_DISK" = yes ]; then
  VERDICT=PASS
fi

{
  echo "PHASE 6 — thin end-to-end (red -> green inner loop)"
  echo "====================================================="
  if [ "$BEFORE_RC" -ne 0 ]; then
    echo "gate_before   : rc=$BEFORE_RC  RED  (acceptance failing, as expected)"
  else
    echo "gate_before   : rc=$BEFORE_RC  UNEXPECTEDLY GREEN"
  fi
  echo "claude_exit   : $CLAUDE_RC"
  echo "marker_on_disk: $MARKER_ON_DISK"
  if [ "$AFTER_RC" -eq 0 ]; then
    echo "gate_after    : rc=$AFTER_RC  GREEN (acceptance satisfied via MCP)"
  else
    echo "gate_after    : rc=$AFTER_RC  STILL RED"
  fi
  echo "-----------------------------------------------------"
  echo "VERDICT       : $VERDICT"
} > /proof/result.txt

echo "[*] ============================================================"
cat /proof/result.txt
echo "[*] ============================================================"

kill "$XVFB_PID" 2>/dev/null
[ "$VERDICT" = PASS ] && exit 0 || exit 1
