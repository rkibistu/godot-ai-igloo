#!/usr/bin/env bash
# Phase 3 — prove the MCP bridge comes up. Run INSIDE the container.
#
# Chain under test:  godot_ai editor plugin (enabled) --> WS :9500
#                    --> FastMCP HTTP server :8000 (/mcp, spawned via uvx)
#
# The plugin's _enter_tree() calls _start_server(), which runs
#   uvx --from godot-ai==<ver> godot-ai --transport streamable-http
#       --port 8000 --ws-port 9500 --pid-file <...>
# That uvx fetch needs PyPI egress at runtime (the container has network by
# default; the real amnesiac system must pre-warm the uv cache instead).
#
# The plugin DISABLES itself under true headless (--headless / display "headless"),
# so we run the EDITOR under Xvfb on a real X11 display — exactly the Phase 1 path.
#
# Arg 1 = rendering driver (opengl3|vulkan). NOT `set -e`: we always want the
# diagnostics dump even when a step fails.
set -uo pipefail

DRIVER="${1:-opengl3}"
HTTP_PORT=8000
WS_PORT=9500
WAIT_SECS=150          # uvx cold-start (~30s) + PyPI fetch + editor boot
mkdir -p /proof
echo "[*] Phase 3 — MCP bridge bring-up (driver=$DRIVER)"
echo "[*] uv:  $(command -v uv  || echo MISSING)"
echo "[*] uvx: $(command -v uvx || echo MISSING)"
uv --version 2>/dev/null || echo "[!] uv --version failed"

# 1. Virtual display (same flags as Phase 1)
Xvfb :99 -screen 0 1280x800x24 -ac +extension GLX +render -noreset >/proof/xvfb.log 2>&1 &
XVFB_PID=$!
sleep 2
export DISPLAY=:99

# 2. Pre-import (godot#77508 mitigation). Editor plugins do NOT load during a
#    headless --import, so enabling the plugin first (step 3) is safe.
echo "[*] Importing project (headless)..."
godot --headless --path /project --import >/proof/import.log 2>&1 || echo "[!] import nonzero (often OK)"

# 3. Enable the godot_ai plugin in the container's COPY of project.godot.
#    (Kept out of the committed project.godot so Phase 1's render-isolation
#     stays reproducible.) The [editor_plugins] enabled list is THE canonical
#    enable switch the editor reads on load.
if ! grep -q "godot_ai/plugin.cfg" /project/project.godot; then
  cat >> /project/project.godot <<'EOF'

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_ai/plugin.cfg")
EOF
  echo "[*] Enabled godot_ai plugin in project.godot"
fi

# 4. Launch the EDITOR (NOT --headless) so the plugin's headless-gate stays open
#    and it auto-starts the server.
echo "[*] Launching editor (--rendering-driver $DRIVER)..."
LIBGL_ALWAYS_SOFTWARE=1 godot --editor --path /project --rendering-driver "$DRIVER" --verbose \
    >/proof/editor.log 2>&1 &
EDITOR_PID=$!

# 5. Poll for both ports to listen (or the editor to die).
echo "[*] Waiting up to ${WAIT_SECS}s for :$WS_PORT (ws) and :$HTTP_PORT (http/mcp)..."
WS_UP=0; HTTP_UP=0
DEADLINE=$(( $(date +%s) + WAIT_SECS ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if ! kill -0 "$EDITOR_PID" 2>/dev/null; then
    echo "[!] editor process exited early — see /proof/editor.log"; break
  fi
  ss -ltn 2>/dev/null | grep -q ":$WS_PORT\b"   && WS_UP=1
  ss -ltn 2>/dev/null | grep -q ":$HTTP_PORT\b" && HTTP_UP=1
  if [ "$WS_UP" = 1 ] && [ "$HTTP_UP" = 1 ]; then
    echo "[+] both ports listening"; break
  fi
  sleep 3
done

echo "[*] ---- ss -ltnp (relevant ports) ----"
ss -ltnp 2>/dev/null | grep -E ":($HTTP_PORT|$WS_PORT)\b" || echo "(neither port listening)"

echo "[*] ---- plugin MCP log lines from editor.log ----"
grep -n "MCP |" /proof/editor.log | tail -n 30 || echo "(no 'MCP |' lines)"

# 6. Cheap proof: raw JSON-RPC initialize over HTTP. Shows the server answers
#    and hands back an mcp-session-id even without the SDK.
echo "[*] ---- curl initialize -> /mcp (headers + body) ----"
curl -sS -i --max-time 20 "http://127.0.0.1:$HTTP_PORT/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"phase3-probe","version":"0.0.1"}}}' \
  2>&1 | tee /proof/phase3_initialize.txt | head -n 40 || echo "[!] curl initialize failed"

# 7. Gold proof: full streamable-http handshake via the official MCP client,
#    then tools/list. uv provides its own Python + fetches `mcp` from PyPI.
echo "[*] ---- MCP tools/list via official client (uv run --with mcp) ----"
TOOLS_COUNT=0
uv run --quiet --with mcp python - "$HTTP_PORT" <<'PY' >/proof/phase3_tools.txt 2>&1 || echo "[!] mcp client handshake failed (see /proof/phase3_tools.txt)"
import sys, asyncio
port = sys.argv[1]
url = f"http://127.0.0.1:{port}/mcp"
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

async def main():
    async with streamablehttp_client(url) as (read, write, _get_sid):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            print("SERVER:", init.serverInfo.name, init.serverInfo.version)
            tools = await session.list_tools()
            names = [t.name for t in tools.tools]
            print("TOOLS_COUNT=%d" % len(names))
            for n in sorted(names):
                print("TOOL:", n)

asyncio.run(main())
PY
TOOLS_COUNT=$(grep -oE 'TOOLS_COUNT=[0-9]+' /proof/phase3_tools.txt | head -1 | cut -d= -f2)
TOOLS_COUNT=${TOOLS_COUNT:-0}
echo "[*] tools/list returned $TOOLS_COUNT tools (full list in /proof/phase3_tools.txt)"
head -n 20 /proof/phase3_tools.txt

# 8. Proof screenshot of the editor (dock should show MCP status).
SHOT="/proof/phase3_editor_${DRIVER}.png"
import -window root "$SHOT" 2>/proof/shot.log \
  || ffmpeg -y -f x11grab -video_size 1280x800 -i :99 -frames:v 1 "$SHOT" >/proof/shot.log 2>&1
echo "[*] screenshot -> $SHOT"

# 9. Verdict.
echo "[*] ============================================================"
if [ "$WS_UP" = 1 ] && [ "$HTTP_UP" = 1 ] && [ "$TOOLS_COUNT" -gt 0 ]; then
  echo "[*] PHASE 3: PASS — :$WS_PORT + :$HTTP_PORT listening, tools/list = $TOOLS_COUNT tools"
  VERDICT=0
else
  echo "[*] PHASE 3: FAIL — ws_up=$WS_UP http_up=$HTTP_UP tools=$TOOLS_COUNT"
  echo "[*]          inspect /proof/editor.log, /proof/phase3_tools.txt, /proof/phase3_initialize.txt"
  VERDICT=1
fi
echo "[*] ============================================================"

kill "$EDITOR_PID" 2>/dev/null
kill "$XVFB_PID"   2>/dev/null
exit "$VERDICT"
