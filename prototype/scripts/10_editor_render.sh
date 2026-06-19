#!/usr/bin/env bash
# Phase 1 — prove the Godot EDITOR boots and renders under Xvfb in a GPU-less
# container. Run INSIDE the container. Arg 1 = rendering driver (opengl3|vulkan).
set -uo pipefail

DRIVER="${1:-opengl3}"
mkdir -p /proof
echo "[*] Phase 1 render test — driver=$DRIVER"

# 1. Virtual display
Xvfb :99 -screen 0 1280x800x24 -ac +extension GLX +render -noreset >/proof/xvfb.log 2>&1 &
XVFB_PID=$!
sleep 2
export DISPLAY=:99

# 2. Environment sanity (what GL/Vulkan do we actually have?)
xdpyinfo                              >/proof/xdpyinfo.log  2>&1 || echo "[!] xdpyinfo failed"
LIBGL_ALWAYS_SOFTWARE=1 glxinfo -B    >/proof/glxinfo.log   2>&1 || echo "[!] glxinfo failed"
vulkaninfo --summary                  >/proof/vulkaninfo.log 2>&1 || echo "[!] vulkaninfo failed"

# 3. Build the import cache first (avoids the headless import-on-quit bug, godot#77508)
echo "[*] Importing project (headless)..."
godot --headless --path /project --import >/proof/import.log 2>&1 || echo "[!] import nonzero (often OK)"

# 4. Launch the EDITOR (NOT --headless) under the virtual display
echo "[*] Launching editor (--rendering-driver $DRIVER)..."
LIBGL_ALWAYS_SOFTWARE=1 godot --editor --path /project --rendering-driver "$DRIVER" --verbose \
    >/proof/editor.log 2>&1 &
GODOT_PID=$!

# 5. Give it time to boot + render
sleep 25

# 6. Liveness — a renderer-init crash leaves the process dead
if kill -0 "$GODOT_PID" 2>/dev/null; then
  echo "[OK]   editor process ALIVE after boot"
  ALIVE=1
else
  echo "[FAIL] editor process EXITED during boot — inspect /proof/editor.log"
  ALIVE=0
fi

# 7. Proof screenshot of the editor window
SHOT="/proof/phase1_editor_${DRIVER}.png"
import -window root "$SHOT" 2>/proof/shot.log \
  || ffmpeg -y -f x11grab -video_size 1280x800 -i :99 -frames:v 1 "$SHOT" >/proof/shot.log 2>&1
echo "[*] screenshot -> $SHOT"

echo "[*] ---- tail of /proof/editor.log ----"
tail -n 40 /proof/editor.log

kill "$GODOT_PID" 2>/dev/null
kill "$XVFB_PID"  2>/dev/null
[ "$ALIVE" = "1" ] && echo "[*] PHASE 1: editor stayed alive — check the screenshot is not blank." \
                   || echo "[*] PHASE 1: editor died — see editor.log."
