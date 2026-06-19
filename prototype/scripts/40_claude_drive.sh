#!/usr/bin/env bash
# Phase 4 — Claude Code drives the editor through MCP and MUTATES the project
# ON DISK. Run INSIDE the container. The verdict comes from a file diff, never
# from anything Claude *says*.
#
# Needs auth in the env: CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`) or
# ANTHROPIC_API_KEY. Inject with `docker run -e ...` — never baked in.
#
# Arg 1 = rendering driver (opengl3|vulkan). Not `set -e`: we always want the
# diff + diagnostics even when a step fails.
set -uo pipefail

DRIVER="${1:-opengl3}"
HTTP_PORT=8000
WS_PORT=9500
SCENE=/project/scenes/main.tscn
mkdir -p /proof
echo "[*] Phase 4 — Claude Code drives the editor via MCP (driver=$DRIVER)"

# 0. Auth + CLI sanity.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "[FAIL] no CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY in env."
  echo "       Generate one with 'claude setup-token' and pass it: docker run -e CLAUDE_CODE_OAUTH_TOKEN ..."
  exit 2
fi
echo "[*] claude: $(command -v claude || echo MISSING)"
claude --version 2>/dev/null || echo "[!] claude --version failed"

# 1. Bring up editor + MCP bridge (identical to Phase 3).
Xvfb :99 -screen 0 1280x800x24 -ac +extension GLX +render -noreset >/proof/xvfb.log 2>&1 &
XVFB_PID=$!
sleep 2
export DISPLAY=:99

echo "[*] Importing project (headless)..."
godot --headless --path /project --import >/proof/import.log 2>&1 || echo "[!] import nonzero (often OK)"

if ! grep -q "godot_ai/plugin.cfg" /project/project.godot; then
  cat >> /project/project.godot <<'EOF'

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_ai/plugin.cfg")
EOF
  echo "[*] Enabled godot_ai plugin in project.godot"
fi

echo "[*] Launching editor (--rendering-driver $DRIVER)..."
LIBGL_ALWAYS_SOFTWARE=1 godot --editor --path /project --rendering-driver "$DRIVER" --verbose \
    >/proof/editor.log 2>&1 &
EDITOR_PID=$!

echo "[*] Waiting for MCP bridge (:$HTTP_PORT + :$WS_PORT)..."
BRIDGE_UP=0
DEADLINE=$(( $(date +%s) + 150 ))
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

# 2. Snapshot the target BEFORE Claude touches it (objective baseline).
cp "$SCENE" /proof/main.before.tscn
echo "[*] ---- main.tscn BEFORE ----"; cat /proof/main.before.tscn

# 3. Register the MCP server with Claude Code via an explicit config file
#    (deterministic for headless `-p`; project .mcp.json would need interactive
#    first-use approval that can't happen unattended).
cat > /proof/mcp-config.json <<EOF
{ "mcpServers": { "godot": { "type": "http", "url": "http://127.0.0.1:$HTTP_PORT/mcp" } } }
EOF

# 4. Fire ONE narrow, verifiable instruction, fully unattended. The prompt tells
#    Claude to use the MCP tools (NOT to edit files directly) and to session_activate
#    first — Phase 3 showed writes need an active editor session.
cd /project
PROMPT='Use ONLY the "godot" MCP server tools (do not edit any files directly). Steps: (1) call session_activate, or session_manage with op="list" then activate the session, to attach to the running Godot editor; (2) create a child node of type Node2D named "Marker" under the root node of res://scenes/main.tscn using node_create; (3) persist it to disk with scene_save. Then report the resulting scene hierarchy.'

echo "[*] Running Claude headless (--dangerously-skip-permissions)..."
# IS_SANDBOX=1: Claude Code refuses --dangerously-skip-permissions as root unless
# told it's sandboxed. The ephemeral --rm container IS exactly that.
IS_SANDBOX=1 claude --dangerously-skip-permissions \
  --mcp-config /proof/mcp-config.json \
  -p "$PROMPT" >/proof/claude_output.log 2>&1
CLAUDE_RC=$?
echo "[*] claude exit=$CLAUDE_RC"
echo "[*] ---- tail of claude_output.log ----"
tail -n 40 /proof/claude_output.log

# 5. Snapshot AFTER + the objective diff.
cp "$SCENE" /proof/main.after.tscn
echo "[*] ---- diff main.tscn (before -> after) ----"
diff -u /proof/main.before.tscn /proof/main.after.tscn | tee /proof/main.diff || true

import -window root "/proof/phase4_editor_${DRIVER}.png" 2>/proof/shot.log \
  || ffmpeg -y -f x11grab -video_size 1280x800 -i :99 -frames:v 1 "/proof/phase4_editor_${DRIVER}.png" >/proof/shot.log 2>&1

# 6. Verdict: the scene file must now DEFINE a Node2D named "Marker".
echo "[*] ============================================================"
if grep -qE '\[node name="Marker" type="Node2D"' /proof/main.after.tscn; then
  echo "[*] PHASE 4: PASS — 'Marker' Node2D is objectively on disk in main.tscn"
  VERDICT=0
else
  echo "[*] PHASE 4: FAIL — no 'Marker' Node2D in main.tscn after Claude run"
  echo "[*]          inspect /proof/claude_output.log, /proof/main.diff, /proof/editor.log"
  VERDICT=1
fi
echo "[*] ============================================================"

kill "$EDITOR_PID" 2>/dev/null
kill "$XVFB_PID"   2>/dev/null
exit "$VERDICT"
