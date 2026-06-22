#!/usr/bin/env bash
# Checkpoint (Phase 1, task #5): inspect the godot_ai MCP tool surface for
# C#-script capability. Brings the editor+MCP bridge up under Xvfb (the proven
# prototype path) and dumps the tool list + the input schema of every tool that
# mentions "script", plus node_create's schema. No LLM involved.
set -uo pipefail
DRIVER=opengl3
HTTP_PORT=8000
WS_PORT=9500
mkdir -p /proof

# Ensure the godot_ai plugin is present in the (bind-mounted) project.
if [ ! -d /project/addons/godot_ai ]; then
  echo "[*] cloning godot_ai v2.7.5..."
  git clone --depth 1 --branch v2.7.5 https://github.com/hi-godot/godot-ai.git /tmp/godotai >/proof/clone.log 2>&1
  mkdir -p /project/addons
  cp -r /tmp/godotai/plugin/addons/godot_ai /project/addons/godot_ai
fi

Xvfb :99 -screen 0 1280x800x24 -ac +extension GLX +render -noreset >/proof/xvfb.log 2>&1 &
sleep 2
export DISPLAY=:99

echo "[*] importing project (headless)..."
godot --headless --path /project --import >/proof/import.log 2>&1 || true

# Enable the plugin (editor reads [editor_plugins] on load).
if ! grep -q "godot_ai/plugin.cfg" /project/project.godot; then
  cat >> /project/project.godot <<'EOF'

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_ai/plugin.cfg")
EOF
  echo "[*] enabled godot_ai plugin"
fi

echo "[*] launching editor..."
LIBGL_ALWAYS_SOFTWARE=1 godot --editor --path /project --rendering-driver "$DRIVER" --verbose \
    >/proof/editor.log 2>&1 &
EDITOR_PID=$!

echo "[*] waiting for MCP bridge (:$HTTP_PORT + :$WS_PORT, up to 150s)..."
DEADLINE=$(( $(date +%s) + 150 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  kill -0 "$EDITOR_PID" 2>/dev/null || { echo "[!] editor died early"; break; }
  if ss -ltn 2>/dev/null | grep -q ":$WS_PORT\b" && ss -ltn 2>/dev/null | grep -q ":$HTTP_PORT\b"; then
    echo "[+] bridge up"; break
  fi
  sleep 3
done

uv run --quiet --with mcp python - "$HTTP_PORT" <<'PY' 2>&1 | tee /proof/mcp_tools.txt
import sys, asyncio, json
url = f"http://127.0.0.1:{sys.argv[1]}/mcp"
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
async def main():
    async with streamablehttp_client(url) as (r, w, _):
        async with ClientSession(r, w) as s:
            init = await s.initialize()
            print("SERVER:", init.serverInfo.name, init.serverInfo.version)
            tools = (await s.list_tools()).tools
            print("TOOLS_COUNT=%d" % len(tools))
            for t in sorted(tools, key=lambda x: x.name):
                print("TOOL:", t.name)
            print("\n==== schemas: tools mentioning 'script', + node_create/create_node ====")
            for t in tools:
                blob = (t.name + " " + (t.description or "")).lower()
                if "script" in blob or t.name in ("node_create", "create_node"):
                    print("\n#", t.name, "-", (t.description or "").strip()[:240])
                    print(json.dumps(t.inputSchema, indent=2)[:1500])
asyncio.run(main())
PY

kill "$EDITOR_PID" 2>/dev/null
