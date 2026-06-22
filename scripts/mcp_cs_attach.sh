#!/usr/bin/env bash
# Checkpoint (task #5) part 2: can MCP attach a C# (.cs) script to a node?
# Models the real work flow: the agent writes the .cs DIRECTLY, then uses MCP
# (script_attach) to bind it to a node and scene_save. Verdict = the .tscn on disk.
set -uo pipefail
DRIVER=opengl3
HTTP_PORT=8000
WS_PORT=9500
mkdir -p /proof

# (agent writes the .cs directly — not via MCP)
mkdir -p /project/scripts
cat > /project/scripts/Widget.cs <<'CS'
using Godot;

public partial class Widget : Node2D
{
    public override void _Ready() => GD.Print("WIDGET_READY");
}
CS

# Plugin present?
if [ ! -d /project/addons/godot_ai ]; then
  git clone --depth 1 --branch v2.7.5 https://github.com/hi-godot/godot-ai.git /tmp/godotai >/proof/clone.log 2>&1
  mkdir -p /project/addons && cp -r /tmp/godotai/plugin/addons/godot_ai /project/addons/godot_ai
fi

# Compile so the CSharpScript type resolves when attached.
echo "[*] dotnet build..."
dotnet build /project --nologo -v quiet 2>&1 | tail -5

Xvfb :99 -screen 0 1280x800x24 -ac +extension GLX +render -noreset >/proof/xvfb.log 2>&1 &
sleep 2
export DISPLAY=:99
godot --headless --path /project --import >/proof/import.log 2>&1 || true
grep -q "godot_ai/plugin.cfg" /project/project.godot || cat >> /project/project.godot <<'EOF'

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_ai/plugin.cfg")
EOF

LIBGL_ALWAYS_SOFTWARE=1 godot --editor --path /project --rendering-driver "$DRIVER" --verbose >/proof/editor.log 2>&1 &
EDITOR_PID=$!
DEADLINE=$(( $(date +%s) + 150 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  kill -0 "$EDITOR_PID" 2>/dev/null || { echo "[!] editor died"; break; }
  ss -ltn 2>/dev/null | grep -q ":$WS_PORT\b" && ss -ltn 2>/dev/null | grep -q ":$HTTP_PORT\b" && { echo "[+] bridge up"; break; }
  sleep 3
done

cp /project/scenes/main.tscn /proof/main.before.tscn

uv run --quiet --with mcp python - "$HTTP_PORT" <<'PY' 2>&1 | tee /proof/mcp_attach.txt
import sys, asyncio, json, re
url = f"http://127.0.0.1:{sys.argv[1]}/mcp"
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

def texts(res):
    out = []
    for c in getattr(res, "content", []) or []:
        out.append(getattr(c, "text", str(c)))
    return ("ERR " if getattr(res, "isError", False) else "") + " | ".join(out)

async def call(s, name, args):
    try:
        r = await s.call_tool(name, arguments=args)
        print(f"\n>>> {name}({args})\n{texts(r)[:1200]}")
        return r
    except Exception as e:
        print(f"\n>>> {name}({args})\nEXCEPTION: {e}")
        return None

async def main():
    async with streamablehttp_client(url) as (r, w, _):
        async with ClientSession(r, w) as s:
            await s.initialize()
            # schemas we need
            tools = {t.name: t for t in (await s.list_tools()).tools}
            for n in ("session_activate", "session_manage", "scene_save", "scene_get_hierarchy"):
                if n in tools:
                    print(f"## {n} schema:\n{json.dumps(tools[n].inputSchema)[:600]}")
            # activate the (only) editor session
            lst = await call(s, "session_manage", {"op": "list"})
            sid = ""
            if lst:
                m = re.search(r'"(?:session_id|id)"\s*:\s*"([^"]+)"', texts(lst))
                if m: sid = m.group(1)
            await call(s, "session_activate", {"session_id": sid} if sid else {})
            # create a child node, attach the .cs, save
            await call(s, "node_create", {"type": "Node2D", "name": "CsHost", "parent_path": ""})
            await call(s, "scene_get_hierarchy", {})
            # try the two plausible node paths
            for npath in ("/Main/CsHost", "/root/CsHost", "CsHost"):
                rr = await call(s, "script_attach", {"path": npath, "script_path": "res://scripts/Widget.cs"})
                if rr and not getattr(rr, "isError", False):
                    break
            await call(s, "scene_save", {})
asyncio.run(main())
PY

echo "[*] ===== main.tscn AFTER ====="
cat /project/scenes/main.tscn
echo "[*] ===== verdict ====="
grep -qE 'Widget\.cs' /project/scenes/main.tscn && echo "CS_ATTACH=YES (Widget.cs referenced in scene)" || echo "CS_ATTACH=NO"
kill "$EDITOR_PID" 2>/dev/null
