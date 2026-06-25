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

# Per-project skills live in the game repo at .igloo/skills/ (committed; arrive via the clone — no
# host mount). Governing prompt is chosen by the run class: a fix run addresses review threads, a
# fresh/resume run implements the issue. Both work models are otherwise identical.
SKILLS_DIR="${IGLOO_SKILLS_DIR:-/project/.igloo/skills}"
case "$CLASS" in
  fix) SKILL="$SKILLS_DIR/fix-comments.md" ;;
  *)   SKILL="$SKILLS_DIR/fresh-implement.md" ;;
esac

# Mechanical contract block, generated from .igloo.yml — the SAME source the done-gate reads, so the
# agent is told exactly what will be verified and cannot drift from it (skills must NOT restate the
# contract; ADR-0004 decision 3). agent_run exports IGLOO_CONFIG=/project/.igloo.yml.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/config.sh"
SCENE_REL="$(cfg_subst "$(cfg_get .issue_scene.scene 'test/scenes/issue_{n}.tscn')" "$ISSUE")"
SCRIPT_REL="$(cfg_subst "$(cfg_get .issue_scene.script 'test/scenes/Issue{n}.cs')" "$ISSUE")"
CLASS_NAME="$(cfg_subst "$(cfg_get .issue_scene.class 'Issue{n}')" "$ISSUE")"
TEST_CMD="$(cfg_get .test_command 'dotnet test')"
GAME_SUBDIR="${GAME_SUBDIR:-${GAME_DIR#/project/}}"; [ "$GAME_SUBDIR" = "/project" ] && GAME_SUBDIR=""
CONTRACT="MECHANICAL CONTRACT — the done-gate verifies these objectively (non-negotiable):
- Issue scene MUST exist at res://$SCENE_REL
- Its C# script at ${GAME_SUBDIR:+$GAME_SUBDIR/}$SCRIPT_REL, class $CLASS_NAME
- The full test suite ($TEST_CMD, run in the game project) MUST pass
- The Issue scene MUST boot cleanly and self-quit (exit 0)"

HTTP_PORT=8000; WS_PORT=9500; DRIVER=opengl3
export DISPLAY=:99
ulimit -c 0   # software-GL teardown can SIGSEGV on kill; suppress core dumps

# Credit-free check: assert the right skill is chosen AND the contract renders for this class, then
# exit BEFORE any editor/MCP bring-up or claude call (no token needed). Used by the proof.
if [ "${CLAUDE_DRYRUN:-}" = "1" ]; then
  echo "DRYRUN: class=$CLASS skill=$SKILL"
  echo "----- contract -----"; printf '%s\n' "$CONTRACT"
  exit 0
fi

[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || {
  echo "CLAUDE_CODE_OAUTH_TOKEN unset — cannot invoke the agent" > "$RUNS_DIR/BLOCKED"
  echo "agent_real: no Claude token -> BLOCKED"; exit 0; }
[ -f "$SKILL" ] || { echo "skill not found at $SKILL (seed .igloo/skills/ via 'igloo init')" > "$RUNS_DIR/BLOCKED"; echo "agent_real: skill missing"; exit 0; }

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

# The contract block (generated from .igloo.yml) is injected into BOTH classes so the agent always
# knows what the gate will re-verify; a fix payload also carries surgical framing + the threads, a
# fresh payload the issue body. The payload is appended after the contract.
if [ "$CLASS" = "fix" ]; then
  PROMPT="Address the PR review comments below for issue #$ISSUE — a surgical fix; reply in-thread on each.

$CONTRACT

$(cat "$PAYLOAD")"
else
  PROMPT="Implement GitHub issue #$ISSUE.

$CONTRACT

$(cat "$PAYLOAD")"
fi

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
