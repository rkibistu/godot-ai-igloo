# Prototype Engineering Notes

Running log of what we actually learned building the feasibility prototype. The plan
and pass/fail verdicts live in `../plan_prototype.md`; this file is the *why it
behaved that way* and *what it means for the real system*.

---

## Phases 0–1 (2026-06-19) — editor renders headless: CONFIRMED

The single scariest assumption in `ArhitectureConcept` / `plan_workflow.md` — that the
full Godot **editor** (not just the runtime) can render inside a GPU-less container —
is **true**. Everything else in the concept is downstream of this, so this is the
result that mattered most.

### What worked
- **Software rendering is enough.** Godot 4.6.3 editor ran on **Mesa llvmpipe (CPU)**,
  not a GPU: `OpenGL API 4.5 … Using Device: Mesa – llvmpipe (LLVM 20.1.2) … CPU`.
  This is the property that keeps the "no GPU / future remote execution" goal alive —
  the image is portable to any plain Linux host or cloud runner.
- **The winning driver combo** (first attempt, no fallback needed):
  - project setting `rendering/renderer/rendering_method="gl_compatibility"`,
  - launch flag `--rendering-driver opengl3`,
  - env `LIBGL_ALWAYS_SOFTWARE=1` so Mesa picks llvmpipe.
  The Vulkan + lavapipe path was prepared (`mesa-vulkan-drivers` is installed) but never
  needed. Keep it as the documented fallback.
- **Editor, not `--headless`.** We launch under `Xvfb :99` with a *real* virtual
  display, deliberately NOT `--headless` (which disables rendering and would blind VNC
  and the editor plugin). `--headless` is reserved for the eyeless test/scene runs
  (Phase 5).
- **Cheap, reliable Phase-1 proxy:** "editor process still alive after ~25s" + "screen
  grab is not blank." The screenshot showed a fully-drawn editor (viewport + rulers,
  FileSystem dock, bottom panel, version badge).
- **Addons load without crashing the editor.** GUT and godot_ai are vendored into the
  project; the editor scanned/loaded GUT's resources during boot with no error, even
  though neither plugin is *enabled* yet. Good signal for Phase 3.

### Gotchas & how we handled them
- **Import before launch.** Run `godot --headless --path /project --import` to build the
  `.godot` import cache *before* opening the editor. This sidesteps the headless
  import-on-quit bug (godot#77508) and means the editor opens an already-imported
  project.
- **Cursor warnings are noise.** `Failed loading custom cursor: left_ptr …` appears
  because there's no X cursor theme under Xvfb. Harmless. Silence later with
  `adwaita-icon-theme` / `dmz-cursor-theme` if we care.
- **Ubuntu 24.04 (noble) package name:** it's `libasound2t64`, not `libasound2`.
  `mesa-utils`→`glxinfo`, `vulkan-tools`→`vulkaninfo`, `mesa-vulkan-drivers`→lavapipe.
- **Window isn't maximized** to the Xvfb screen (black border around it in the grab).
  Cosmetic; revisit when we wire VNC (Phase 2) so the human sees a full window.

### Implications for the real system (carry-forward)
- **Pre-bake or cache the `.godot` import directory.** Under the amnesiac
  `docker run --rm` model, *every* cold run re-imports the project from scratch. For a
  small project that's seconds; for a real game it won't be. Options: bake a warmed
  `.godot/` into the image at build time, or commit/restore it. Decide during the real
  Docker-image build (currently deferred).
- **llvmpipe is CPU-bound.** Editor UI renders fine, but *running an actual game scene*
  (Phase 5/6) on a software rasterizer is untested and may be slow for anything
  graphically heavy. Logic-only scenes (the concept's target) should be fine; keep an
  eye on it. GPU passthrough remains the speed escape hatch for local runs.
- **Image is ~1.35 GB.** ffmpeg + imagemagick + full Mesa stack dominate. Fine for the
  prototype; slim later (drop imagemagick in favor of ffmpeg-only capture, trim Mesa).

### Everything is pinned (reproducible)
`ubuntu:24.04` · Godot `4.6.3-stable` (standard/GDScript) · GUT `9.3.1` ·
hi-godot/godot-ai `v2.7.5` · uv `0.11.22`. Chose 4.6.3 over the 1-day-old 4.7-stable on
purpose — fewer unknowns in a feasibility test; trivially bumpable via the `GODOT_VERSION`
build arg.

### Open questions pushed to the next phases
- ~~**Phase 3:** Does godot_ai auto-start its WS server (:9500)? Does the FastMCP HTTP
  server (:8000) come up, and does `uvx` need network at runtime?~~ **ANSWERED below.**
- **Phase 4:** Can Claude Code register the HTTP MCP server and issue ops that *mutate
  the project on disk* (verified by `git diff`, never by the LLM's word)?
- **Phase 2:** Does x11vnc on :99, port-mapped out of the `--rm` container, give a usable
  live view from the host?

---

## Phase 3 (2026-06-19) — MCP bridge comes up: CONFIRMED

The second-scariest assumption — that hi-godot's editor plugin can stand up its
WebSocket↔HTTP bridge inside the container and an MCP client can actually talk to it —
is **true**. Enabling the plugin and launching the editor under Xvfb auto-started the
entire chain with no manual server step.

### What worked
- **Plugin autostart fires.** `_enter_tree()` → `_start_server()` ran on editor boot.
  Editor log: `MCP | using uvx (godot-ai==2.7.5)` → `MCP | started server (PID …)` →
  (4 reconnect attempts, backoff 1→2→4→8s) → `MCP | connected to server`. The WS client
  in the editor reconnects until the freshly-spawned Python server binds — expected, not
  an error.
- **Both ports listen**, owned by the uvx-spawned `python` (one process serves both):
  `127.0.0.1:9500` (WS, editor↔server) and `127.0.0.1:8000` (HTTP `/mcp`, client↔server).
- **A real MCP handshake works.** `initialize` over streamable-http → `200 OK`,
  `server: uvicorn`, an `mcp-session-id`, full capabilities. `tools/list` returned
  **41 tools** (incl. `node_create`, `scene_open`/`scene_save`, `session_activate`,
  `script_patch`, `test_run`, `project_run`) — i.e. everything Phases 4–5 need.
- **Visual proof:** `proof/phase3_editor_opengl3.png` shows the **Godot AI dock with a
  green "Connected"** dot and "Install: v2.7.5". Confirms the bridge is live, not just
  ports open.

### How the spawn actually resolves (read from the plugin source)
`client_configurator.gd` resolves the server command in three tiers — **(1) `.venv`
python → (2) `uvx` → (3) system `godot-ai` CLI**. Our image has none of the first/third,
so it lands on **uvx**: `uvx --from godot-ai==<plugin_version> godot-ai --transport
streamable-http --port 8000 --ws-port 9500 --pid-file <…>`. Ports come from
`DEFAULT_HTTP_PORT=8000` / `DEFAULT_WS_PORT=9500` (overridable via EditorSettings).

### Gotchas & decisions
- **Must NOT be `--headless`.** The plugin self-disables when `--headless`,
  `--display-driver headless`, or `DisplayServer.get_name()=="headless"` (overridable via
  `GODOT_AI_ALLOW_HEADLESS`). We run `--editor` under Xvfb on a real X11 display, so the
  gate stays open and the dock (an editor UI element) can be created. This is the
  concrete reason the whole concept needs a virtual display, not headless.
- **`uvx` needs PyPI egress at runtime.** First spawn fetches `godot-ai==2.7.5` + deps
  (the source notes uvx cold-starts can take ~30s). The prototype container has default
  network, so it just worked. **Carry-forward for the amnesiac `--rm` system: pre-warm
  the uv cache (or `pip install godot-ai` into the image) at build time** so cold runs
  don't re-download — same class of problem as pre-baking the `.godot` import cache.
- **Plugin enabled at container runtime, not committed.** `30_mcp_up.sh` appends the
  `[editor_plugins] enabled=…` line to the container's copy of `project.godot`, leaving
  the committed file plugin-free so Phase 1's render-isolation stays reproducible.
- **Added `iproute2`** to the image for `ss` (was missing; the base had no netstat either).
- **Version decoupling (flag for the real system):** dock + plugin report **v2.7.5**, but
  the running server's `serverInfo.version` is **3.4.2**. It connected with no
  incompatibility warning, so the PyPI server package and the GDScript plugin clearly
  version independently — understand this relationship before pinning both for real.

### Implication for Phase 4
The 41 tools are present and the transport is `http://127.0.0.1:8000/mcp` — exactly what
`claude mcp add --transport http` expects. Phase 4 is now unblocked: register that URL
with Claude Code and have it call `node_create` + `scene_save`, then verify with
`git diff` (note: writes require `session_activate` / editor readiness first, per the
server's own `initialize` instructions).

---

## How to reproduce

```sh
cd prototype
./scripts/00_build.sh            # Phase 0/1: build image + run the opengl3 render test
# -> prototype/proof/phase1_editor_opengl3.png  (the verdict)

./scripts/01_phase3.sh           # Phase 3: MCP bridge bring-up (needs network for uvx)
# -> prototype/proof/phase3_tools.txt          (tools/list = 41)
# -> prototype/proof/phase3_editor_opengl3.png (dock shows green "Connected")
# -> prototype/proof/phase3_initialize.txt, editor.log
```
