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

## Phase 4 (2026-06-19) — Claude Code drives the editor: CONFIRMED

The third-scariest assumption — that an LLM agent can drive the editor *unattended*
through MCP and actually change the project — is **true**. This is the phase that proves
the system can do work, not just connect.

### What worked
- **One headless instruction → a real, on-disk change.** `claude -p "...use the godot MCP
  tools to session_activate, add a Node2D 'Marker' to main.tscn, scene_save..."` ran with
  no human in the loop and produced `[node name="Marker" type="Node2D" parent="."]` in
  `main.tscn`. **Verdict is the file diff (`proof/main.diff`), never Claude's word.**
- **The full chain is visible in the editor log:** `Session connected: project@… (pid=274,
  Godot 4.6.3)` → `ListToolsRequest` → `CallToolRequest`×N →
  `MCP | [recv] create_node({"name":"Marker",…,"type":"Node2D"})`. So Claude → HTTP :8000
  → WS :9500 → editor → disk, end to end.
- **Auth via Pro subscription token.** `claude setup-token` → injected as
  `CLAUDE_CODE_OAUTH_TOKEN` through `docker run -e` (passthrough, never in a file or the
  image). Worked first try once the root gate below was cleared.

### Gotchas & how we handled them (both matter for the real system)
- **`--dangerously-skip-permissions` is refused under root** (the container's default
  user): *"cannot be used with root/sudo privileges for security reasons"* — Claude exits
  immediately, does nothing. **Fix: `IS_SANDBOX=1`** in the env for the `claude` call
  (the ephemeral `--rm` container genuinely is a sandbox). Verified both forms clear the
  gate. The real system must set `IS_SANDBOX=1` or run Claude as a non-root user.
- **The editor re-serializes the whole `.tscn` on first save.** The diff wasn't a clean
  one-liner — Godot also added `uid="uid://…"` to the scene + ext_resource, added
  `unique_id=…` to nodes, and dropped `load_steps`. Expected Godot behaviour. **Implication:
  git-diff verification in the real system will see editor-normalized noise; assert on the
  meaningful line (the new node), not on diff size.**
- **On-wire op name differs from the tool name:** the advertised MCP tool is `node_create`,
  but the dispatch verb in the editor log is `create_node`. Cosmetic, but don't be thrown
  by it when grepping logs.
- **Claude Code in the image:** native installer (`curl -fsSL https://claude.ai/install.sh
  | bash`) → `/root/.local/bin/claude` (v2.1.183), no Node needed. Registered the server
  with `--mcp-config <file>` (explicit, deterministic for `-p`) rather than a project
  `.mcp.json`, which would need interactive first-use approval that can't happen headless.

### Implication for Phase 5
The write path works. Next is the *objective done-gate* with zero LLM involvement: a plain
script runs the scene headless + GUT from CLI and decides PASS/FAIL from exit codes /
sentinel / `gut.xml`. The Phase-4 finding that the editor reformats scenes on save is also
relevant to Phase 5's "commit/restore `.godot` import cache" question.

---

## Phase 5 (2026-06-19) — objective, LLM-free done-gate: CONFIRMED

A plain shell script decides PASS/FAIL with **zero** Claude/MCP/editor/network. This is
the referee the autonomous loop trusts instead of the agent's word.

### What worked
- **Gate 1 (run-scene):** `godot --headless --path /project res://scenes/main.tscn` →
  assert `exit 0` **and** sentinel `PROTO_SENTINEL_READY` present **and** no `ERROR`.
  `main.gd` self-quits via a 1s timer so it terminates deterministically.
- **Gate 2 (GUT):** `godot --headless -s res://addons/gut/gut_cmdln.gd -gdir=res://test
  -gexit -gjunit_xml_file=/proof/gut.<tag>.xml` → assert process `exit 0`.
- **Verdict = Gate1 AND Gate2**, printed once, derived only from exit codes + `grep`.
- **Honesty proven by the flip:** the host driver runs the gate twice — clean → PASS
  (rc 0), deliberately broken → FAIL (rc 1). Proof in the JUnit XML:
  `gut.clean.xml` `failures="0" tests="2"` vs `gut.break.xml` `failures="1" tests="2"`.

### Gotchas & how we handled them
- **GUT must be ≥ 9.4.0 on Godot 4.6.** 9.3.x declares `static var Logger`, which shadows
  Godot 4.6's new **native `Logger`** class → parse error → GUT won't load (cascade of
  `get_logger`/`set_gut` nil errors), and the process hangs until `timeout` (rc 124).
  Fixed by pinning **GUT v9.6.0** in the Dockerfile (renamed to `GutLogger`). *Lesson:
  third-party Godot addons need a version compatible with the exact engine version — the
  real system must pin/verify GUT vs Godot together.*
- **`-gexit` sets a non-zero process exit on failure** (1 here), so GUT's exit code is a
  sufficient signal; the JUnit XML is a bonus human-readable artifact.
- **`tee` masks the real exit code** — recover via `${PIPESTATUS[0]}`. An OS-level
  `timeout` wraps both godot calls as the unambiguous safety net (kill → rc 124 → FAIL).
- **Sabotage is ephemeral & safe:** `break` mode `sed`-corrupts a GUT assertion *inside*
  the `--rm` container; `/project` is COPY'd into the image, so the committed host source
  is untouched.

### Implication for Phase 6
The done-gate is buildable and trustworthy. Phase 6 chains it after a Claude/MCP change:
cold container → Claude edits via MCP (Phase 4) → run this gate (Phase 5) → capture proof
(ffmpeg/screenshot off `:99`) → write `/proof/result.txt`. Carry-forward for the real
system: pin GUT to the engine version, and pre-build/commit the `.godot` import cache to
avoid paying the per-cold-container import each run.

---

## Phase 6 (2026-06-19) — thin end-to-end inner loop: CONFIRMED

The concept's whole inner loop, once, in a single cold container. **PASS.**

### What worked
- **A real red → green task.** An acceptance test ("`main.tscn` must contain a child
  `Node2D` named `Marker`") is **injected into the ephemeral container at runtime** (never
  committed — that would break Phase 5's clean run). It encodes the objective as a
  machine-checkable spec: "a task arrives."
- **Same referee, before and after.** The *unchanged* `50_gate.sh` judges: BEFORE Claude →
  **RED** (`gut.before.xml` `failures="1"`), AFTER Claude → **GREEN** (`gut.after.xml`
  `failures="0"`). Reusing the exact Phase 5 gate is what makes the demo honest.
- **Claude closed the gap via MCP** (the proven Phase 4 action: `node_create` Marker +
  `scene_save`), `claude_exit=0`, Marker on disk in `main.diff`.
- **Verdict from files only:** `PASS  iff  gate_before != 0  AND  gate_after == 0  AND
  Marker grep'd in main.after.tscn` → written to `proof/result.txt`.

### Gotchas & how we handled them
- **Tear the editor down before the AFTER gate.** Two godot processes on the same project
  (editor + headless gate run) can contend on the `.godot` import cache; kill the editor +
  `sleep 3` first.
- **Windowed-game capture is timing-fragile.** We extend `main.gd`'s self-quit to 8s *after*
  both gates (affects no verdict) and grab with ffmpeg/`import`, but the artifacts come out
  small/near-blank — the grab races godot's slow llvmpipe startup. The **editor screenshot
  (29K) is the reliable rendering proof**; the gameplay clip is bonus, and live observation
  is descoped anyway. Real-system fix: gate the capture on a deterministic "rendered"
  signal, not a wall-clock `sleep`.
- **No-token pre-check pays off.** The acceptance-test + gate wiring (red→green) was
  validated against the image with a throwaway helper *before* spending a Pro token; only
  the already-proven Claude/MCP step then needed the real run.

### Bottom line
All in-scope exit criteria are green (4 of 4; VNC descoped). The feasibility question
— "does godot + hi-godot work in a GPU-less container well enough for an autonomous,
objectively-judged dev loop?" — is answered **yes**. Next is the real outer loop
(`plan_workflow.md`): GitHub-as-DB, ephemeral runners, triage, etc.

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

# Phase 4 needs a Claude auth token, passed through from the host env:
claude setup-token                          # one-time, in a normal terminal -> prints token
export CLAUDE_CODE_OAUTH_TOKEN=<that-token>
./scripts/02_phase4.sh           # Claude drives the editor via MCP, mutates main.tscn
# -> prototype/proof/main.diff                 (the verdict: 'Marker' Node2D added)
# -> prototype/proof/main.after.tscn, claude_output.log, phase4_editor_opengl3.png

./scripts/03_phase5.sh           # Phase 5: LLM-free done-gate, run clean THEN broken
# (no token, no network needed at runtime)
# -> prototype/proof/gut.clean.xml  failures="0"  + gut.clean.log, run.clean.log  (PASS)
# -> prototype/proof/gut.break.xml  failures="1"  + gut.break.log, run.break.log  (FAIL)
# Script exits 0 iff clean PASSES and broken FAILS (the honesty flip).

# Phase 6 needs the Claude token too (drives Claude via MCP, like Phase 4):
export CLAUDE_CODE_OAUTH_TOKEN=<token>
./scripts/04_phase6.sh           # thin end-to-end: inject task -> gate RED ->
                                 # Claude fixes via MCP -> gate GREEN -> proof
# -> prototype/proof/result.txt              (VERDICT: PASS, the red->green loop)
# -> prototype/proof/gut.before.xml (failures=1) -> gut.after.xml (failures=0)
# -> prototype/proof/main.diff, phase6_editor_opengl3.png, game_shot.png, run.mp4
```
