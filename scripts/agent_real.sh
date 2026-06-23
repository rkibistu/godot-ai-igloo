#!/usr/bin/env bash
# Phase-4b REAL agent — the production AGENT_CMD (agent_run_host.sh points here). Brings up
# the Godot editor + godot_ai MCP bridge under Xvfb (the proven Phase-1 recipe), runs headless
# `claude -p` (the fresh-implement skill + the issue payload) so the agent writes C# directly
# and builds the Issue scene via MCP, then tears the editor down so the done-gate gets a clean
# display. agent_run.sh wraps THIS in `timeout` and runs the gate + outcome routing afterward.
#   agent_real.sh <issue#> <class> <payload-file>
# Env (exported by agent_run.sh): RUNS_DIR, GAME_DIR, CLAUDE_CODE_OAUTH_TOKEN, IS_SANDBOX.
set -uo pipefail
ISSUE="${1:?issue}"; CLASS="${2:-fresh}"; PAYLOAD="${3:?payload}"
GAME_DIR="${GAME_DIR:-/project/game}"
RUNS_DIR="${RUNS_DIR:-/tmp/run}"; mkdir -p "$RUNS_DIR"
SKILL="/skills/fresh-implement.md"
HTTP_PORT=8000; WS_PORT=9500; DRIVER=opengl3
export DISPLAY=:99
ulimit -c 0   # software-GL teardown can SIGSEGV on kill; suppress core dumps

[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || {
  echo "CLAUDE_CODE_OAUTH_TOKEN unset — cannot invoke the agent" > "$RUNS_DIR/BLOCKED"
  echo "agent_real: no Claude token -> BLOCKED"; exit 0; }
[ -f "$SKILL" ] || { echo "skill not mounted at $SKILL" > "$RUNS_DIR/BLOCKED"; echo "agent_real: skill missing"; exit 0; }

EDITOR_PID=0; XVFB_PID=0
teardown(){ [ "$EDITOR_PID" -gt 0 ] && kill -9 "$EDITOR_PID" 2>/dev/null; [ "$XVFB_PID" -gt 0 ] && kill -9 "$XVFB_PID" 2>/dev/null; sleep 1; }
trap teardown EXIT

echo "== agent_real: bring up editor + godot_ai MCP bridge =="
# Provision the godot_ai addon from the host-mounted, already-validated copy at /opt/godot_ai
# (read-only). It is gitignored, so it is absent from the fresh clone and stays out of the
# agent's PR. No external network fetch. (Baking it into the image is the deferred optimization.)
if [ ! -d "$GAME_DIR/addons/godot_ai" ] && [ -d /opt/godot_ai ]; then
  echo "agent_real: installing godot_ai addon from /opt/godot_ai…"
  mkdir -p "$GAME_DIR/addons"
  cp -r /opt/godot_ai "$GAME_DIR/addons/godot_ai"
fi
[ -f "$GAME_DIR/addons/godot_ai/plugin.cfg" ] || {
  echo "godot_ai addon unavailable (mount /opt/godot_ai missing?)" > "$RUNS_DIR/BLOCKED"
  echo "agent_real: addon missing -> BLOCKED"; exit 0; }

Xvfb :99 -screen 0 1280x800x24 -ac +extension GLX +render -noreset >"$RUNS_DIR/xvfb.editor.log" 2>&1 &
XVFB_PID=$!
sleep 2
godot --headless --path "$GAME_DIR" --import >"$RUNS_DIR/import.editor.log" 2>&1 || true
dotnet build "$GAME_DIR" --nologo -v quiet >"$RUNS_DIR/build.editor.log" 2>&1 || true
# Plugin is enabled in the committed project.godot; re-assert idempotently just in case.
grep -q "godot_ai/plugin.cfg" "$GAME_DIR/project.godot" || cat >> "$GAME_DIR/project.godot" <<'EOF'

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_ai/plugin.cfg")
EOF
LIBGL_ALWAYS_SOFTWARE=1 godot --editor --path "$GAME_DIR" --rendering-driver "$DRIVER" \
  >"$RUNS_DIR/editor.log" 2>&1 &
EDITOR_PID=$!

echo "== wait for MCP bridge (:$HTTP_PORT + :$WS_PORT, up to 150s) =="
DEADLINE=$(( $(date +%s) + 150 )); BRIDGE=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  kill -0 "$EDITOR_PID" 2>/dev/null || { echo "agent_real: editor died early"; break; }
  if ss -ltn 2>/dev/null | grep -q ":$WS_PORT\b" && ss -ltn 2>/dev/null | grep -q ":$HTTP_PORT\b"; then BRIDGE=1; break; fi
  sleep 3
done
if [ "$BRIDGE" != 1 ]; then
  echo "editor/MCP bridge did not start (see runs/.../editor.log)" > "$RUNS_DIR/BLOCKED"
  echo "agent_real: bridge DOWN -> BLOCKED"; exit 0
fi
echo "agent_real: bridge up at http://127.0.0.1:$HTTP_PORT/mcp"

# Claude Code MCP config (HTTP transport to the in-editor bridge).
MCP_CFG="$RUNS_DIR/mcp.json"
cat > "$MCP_CFG" <<JSON
{"mcpServers":{"godot_ai":{"type":"http","url":"http://127.0.0.1:$HTTP_PORT/mcp"}}}
JSON

PROMPT="Implement GitHub issue #$ISSUE. The Issue scene MUST be at res://test/scenes/issue_$ISSUE.tscn (script game/test/scenes/Issue$ISSUE.cs, class Issue$ISSUE).

$(cat "$PAYLOAD")"

# --dangerously-skip-permissions auto-approves all tools (incl. the configured MCP server);
# IS_SANDBOX=1 (set in the image) makes that safe as root in this --rm container.
echo "== invoke claude -p (cwd /project) =="
cd /project
claude -p "$PROMPT" \
  --append-system-prompt "$(cat "$SKILL")" \
  --mcp-config "$MCP_CFG" \
  --dangerously-skip-permissions \
  >"$RUNS_DIR/claude.log" 2>&1
CRC=$?
echo "agent_real: claude rc=$CRC (transcript: runs/.../claude.log)"
exit "$CRC"
