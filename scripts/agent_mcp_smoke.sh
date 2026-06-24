#!/usr/bin/env bash
# Phase-4b CREDIT-FREE de-risk: bring up the editor + godot_ai MCP bridge exactly like
# agent_real.sh does, then prove the plumbing WITHOUT any LLM generation:
#   (a) the bridge is reachable + lists tools (proven Phase-1 Python MCP client), and
#   (b) `claude` is installed and parses an HTTP MCP config (sees the godot_ai server).
# Run this until green BEFORE spending any credits on the one real `claude -p` run.
#   bash scripts/agent_mcp_smoke.sh
set -uo pipefail
IMG=godot-ai-igloo:dev
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
mkdir -p "$ROOT/proof"
[ -f .env ] && { set -a; . ./.env; set +a; }   # optional CLAUDE token; not required here

docker run --rm -i \
  -e CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
  -e IS_SANDBOX=1 \
  -v "$ROOT/game:/project" -v "$ROOT/scripts:/scripts" -v "$ROOT/proof:/proof" \
  "$IMG" bash -s <<'INCONTAINER'
set -uo pipefail
HTTP_PORT=8000; WS_PORT=9500; DRIVER=opengl3
export DISPLAY=:99; ulimit -c 0

echo "== claude presence =="
command -v claude >/dev/null && claude --version 2>&1 | head -1 || echo "WARN: claude not on PATH"

echo "== bring up editor + MCP bridge (against /project = game) =="
Xvfb :99 -screen 0 1280x800x24 -ac +extension GLX +render -noreset >/proof/smoke.xvfb.log 2>&1 &
XVFB=$!; sleep 2
godot --headless --path /project --import >/proof/smoke.import.log 2>&1 || true
dotnet build /project --nologo -v quiet >/proof/smoke.build.log 2>&1 || true
grep -q "godot_ai/plugin.cfg" /project/project.godot || cat >> /project/project.godot <<'EOF'

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_ai/plugin.cfg")
EOF
LIBGL_ALWAYS_SOFTWARE=1 godot --editor --path /project --rendering-driver "$DRIVER" >/proof/smoke.editor.log 2>&1 &
ED=$!
DEADLINE=$(( $(date +%s) + 150 )); BRIDGE=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  kill -0 "$ED" 2>/dev/null || { echo "editor died early"; break; }
  ss -ltn 2>/dev/null | grep -q ":$WS_PORT\b" && ss -ltn 2>/dev/null | grep -q ":$HTTP_PORT\b" && { BRIDGE=1; break; }
  sleep 3
done
echo "BRIDGE_UP=$BRIDGE"

RC=1
if [ "$BRIDGE" = 1 ]; then
  echo "== (credit-free) list MCP tools via python client =="
  uv run --quiet --with mcp python - "$HTTP_PORT" <<'PY' 2>&1 | tee /proof/smoke.tools.txt
import sys, asyncio
url=f"http://127.0.0.1:{sys.argv[1]}/mcp"
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
async def main():
    async with streamablehttp_client(url) as (r,w,_):
        async with ClientSession(r,w) as s:
            await s.initialize()
            tools=(await s.list_tools()).tools
            print("TOOLS_COUNT=%d"%len(tools))
            for t in sorted(tools,key=lambda x:x.name): print("TOOL:",t.name)
asyncio.run(main())
PY
  CNT="$(sed -n 's/^TOOLS_COUNT=//p' /proof/smoke.tools.txt | head -1)"
  [ "${CNT:-0}" -gt 0 ] 2>/dev/null && RC=0

  echo "== (credit-free) does claude parse an HTTP MCP config? =="
  echo "{\"mcpServers\":{\"godot_ai\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:$HTTP_PORT/mcp\"}}}" > /project/.mcp.json
  ( cd /project && claude mcp list 2>&1 ) | tee /proof/smoke.claude_mcp.txt || echo "WARN: 'claude mcp list' failed (informational)"
  grep -qi godot_ai /proof/smoke.claude_mcp.txt && echo "CLAUDE_SEES_GODOT_AI=yes" || echo "CLAUDE_SEES_GODOT_AI=no (informational)"
  rm -f /project/.mcp.json
fi

kill -9 "$ED" "$XVFB" 2>/dev/null
echo "SMOKE_RESULT=$([ "$RC" = 0 ] && echo PASS || echo FAIL)"
exit "$RC"
INCONTAINER
RC=$?
echo "============================================================"
if [ "$RC" = 0 ]; then
  echo "MCP SMOKE: PASS — editor + godot_ai bridge up, tools listed (no credits spent)"
else
  echo "MCP SMOKE: FAIL — see proof/smoke.*.log"
fi
exit "$RC"
