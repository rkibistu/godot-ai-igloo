# Feasibility Prototype — Godot + hi-godot MCP in a Container

> This plan is a throwaway, de-risking prototype. Its **only** purpose is to answer
> the question *"can the technical core of `ArhitectureConcept` / `plan_workflow.md`
> actually work?"* before we invest in building the real system. It is written to be
> self-contained: a fresh session with no memory of the design conversation should be
> able to build from it.
>
> **Mindset:** manual, slow, ugly, hard-coded is all fine. More clicks, more commands,
> more hand-holding — fine. We are proving *feasibility*, not shipping a product.
> Every phase ends in a **binary proof**. If a phase fails, we have learned the answer
> cheaply and we stop or pivot.

---

## The core technical fact this prototype exists to test

`hi_godot` is [`hi-godot/godot-ai`](https://github.com/hi-godot/godot-ai). It is an
**editor plugin**, not a headless tool. The full chain that must survive inside a
GPU-less Docker container is four links deep:

```
Claude Code ──MCP/HTTP :8000──► Python FastMCP server (uvx) ──WebSocket :9500──► Godot editor plugin ──► Godot EDITOR (live, under Xvfb)
```

Two consequences drive this entire plan:

1. **The full Godot *editor* must be running and rendering** — not just the runtime.
2. This collides with the docs' "Xvfb headless" wording. Godot's `--headless` flag
   *disables rendering* and blinds any observer. For the editor plugin **and** for
   VNC we need a **real virtual display (Xvfb + software GL/Vulkan)**, which is
   different from `--headless`. We use `--headless` only later, for the throwaway
   test/scene runs that don't need eyes.

---

## What we prove vs. what we deliberately skip

**In scope (the novel, scary inner loop):**
the editor rendering headless · the MCP bridge coming up · Claude driving the editor
through MCP · VNC observation · run-scene/read-logs/GUT done-gate primitives · proof
capture.

**Out of scope (deterministic shell, already trusted by the docs — built later):**
the bot GitHub account · the `gh`/`git` state-machine (fresh/fix/in-review) ·
the fix-loop & PR review threads · `ready-for-agent` gating · secrets-injection
design · the ephemeral `--rm` per-run lifecycle. In the prototype, "GitHub" is faked
with a local bind-mounted copy of the project.

---

## Risks, ranked (these are the phases)

| # | Risk | Why it's the scary one | Phase |
|---|------|------------------------|-------|
| 1 | Godot **editor** renders under Xvfb in a GPU-less container | Godot 4 defaults to Vulkan (needs a GPU). Must prove software rendering (Mesa llvmpipe / lavapipe). **Foundational gate.** | 1 |
| 2 | The two-process MCP bridge (:9500 + :8000) comes up headless | Author never tested headless; needs `uv`, two ports, autostart-on-boot. | 3 |
| 3 | Claude Code actually mutates the project through MCP | Must verify by diffing files on disk, never by trusting the LLM. | 4 |
| 4 | VNC observation of the live editor + a running scene | Your review-flow assumption. Port out of `--rm` container. | 2 |
| 5 | Objective done-gate: run-scene logs + GUT machine-readable pass/fail | "Script decides, never the LLM" depends on this being clean. | 5 |
| 6 | Proof capture (screenshot + ffmpeg clip off the Xvfb display) | Proof-of-work idea from the concept. | 6 |

Lower-risk, noted not blocking: first-run asset import / `.godot` cache cost on every
cold container (Phase 5 note).

---

## Defaults & decisions (change here if wrong)

- **Software rendering, not GPU passthrough.** It is the riskier path *and* the one
  that generalizes to the "remote execution is a clean future swap" goal. If software
  works, local GPU is a free bonus. (Host is TUXEDO OS, likely has a GPU we *could*
  pass through later for speed.)
- **Latest stable Godot 4.x**, standard **GDScript** build (not `.NET`). Pin the exact
  version in the Dockerfile.
- **Base image:** Debian/Ubuntu slim.
- **One image, many manual steps.** No orchestration, no entrypoint state-machine yet.
  We `docker run -it` and run scripts by hand to watch each link.

> Commands below marked *(candidate — verify)* are best-guess and are exactly the
> things the prototype is meant to confirm. Do not treat them as known-good.

---

## Prototype repo layout

```
prototype/
  Dockerfile
  project/                 # the guinea-pig Godot project (Phase 0)
    project.godot
    scenes/main.tscn
    scripts/main.gd        # one testable logic fn + a print
    test/test_main.gd      # a GUT test
    addons/godot_ai/       # hi-godot plugin, vendored
    addons/gut/            # GUT, vendored
  scripts/                 # host + in-container helper scripts (Phase 1+)
    00_build.sh
    10_editor_render.sh
    20_vnc.sh
    30_mcp_up.sh
    40_claude_drive.sh
    50_gate.sh
    60_proof_e2e.sh
  proof/                   # screenshots, clips, logs land here (bind-mounted out)
```

---

## Phase 0 — Scaffold the guinea-pig project (host)

**Goal:** a minimal, deterministic Godot 4.x project that gives every later phase
something concrete to render, mutate, run, and test.

**Build:**
- A new Godot 4.x project under `prototype/project/`.
- `scenes/main.tscn` with a root `Node` (or `Node2D`) and `scripts/main.gd` attached.
- `scripts/main.gd`: a pure, obviously-testable function (e.g. `add(a, b)` or a tiny
  state machine `next_state(cur)`), plus a `_ready()` that `print()`s a known sentinel
  string (so log-capture in Phase 5 has something unambiguous to grep for).
- Vendor **GUT** into `addons/gut/` and one test `test/test_main.gd` that asserts on
  the logic function (one passing, optionally one we can flip to failing on demand).
- Vendor **`hi-godot/godot-ai`** into `addons/godot_ai/` and enable it in
  `project.godot` (`[editor_plugins] enabled=PackedStringArray("res://addons/godot_ai/plugin.cfg")`).

**Success criterion:** project opens in a local Godot editor (or, if no local Godot,
defer the visual check to Phase 1); GUT runs the test green locally if a local Godot
exists. Files committed.

**What we learn / fallbacks:** confirms the addon + GUT layout before we add the
container variable. If there's no local Godot, that's fine — Phase 1 is the first real
render check anyway.

---

## Phase 1 — Editor renders under Xvfb in Docker  *(RISK #1 — the gate)*

**Goal:** prove the **Godot editor** boots and *renders* inside a GPU-less container.

**Build — `prototype/Dockerfile`:**
- Base: `ubuntu:24.04` (or `debian:stable-slim`).
- Install: `xvfb x11vnc ffmpeg libgl1-mesa-dri mesa-utils libvulkan1 mesa-vulkan-drivers vulkan-tools imagemagick curl ca-certificates git unzip`.
- Download + unzip the pinned Godot 4.x Linux binary (`Godot_v4.x-stable_linux.x86_64`)
  to `/usr/local/bin/godot`.
- Install `uv` (`curl -LsSf https://astral.sh/uv/install.sh | sh`) — needed by the MCP
  server in Phase 3.
- Install Claude Code and `gh` (needed Phase 4 / later).
- Copy `project/` to `/project`.

**Run — `scripts/10_editor_render.sh` (inside container):** *(candidate — verify)*
```sh
Xvfb :99 -screen 0 1280x800x24 &
export DISPLAY=:99
# Build the import cache first (avoids the --quit-after import gotcha, godot#77508):
godot --headless --import --path /project || true
# Launch the EDITOR with software rendering. Try opengl3 first:
LIBGL_ALWAYS_SOFTWARE=1 godot --editor --path /project --rendering-driver opengl3 --verbose &
sleep 20
# Prove it actually rendered something:
ffmpeg -y -f x11grab -video_size 1280x800 -i :99 -frames:v 1 /proof/phase1_editor.png
```

**Rendering-driver attempt order (this *is* the experiment):**
1. `--rendering-driver opengl3` + `LIBGL_ALWAYS_SOFTWARE=1` (Mesa **llvmpipe**).
2. `--rendering-driver vulkan` + Mesa **lavapipe** (set `VK_ICD_FILENAMES` to the
   `lvp_icd` json if needed; confirm with `vulkaninfo`).
3. If both fail, capture exact error lines from `--verbose` for diagnosis.

**Success criterion:** the editor process stays alive (doesn't crash on renderer init),
`--verbose` shows no fatal rendering error, and `proof/phase1_editor.png` shows the
actual editor UI (not a blank/black frame).

**What we learn / fallbacks:** which software-rendering path Godot 4 tolerates
headless. If neither works, the fallback is GPU passthrough (`--gpus all` / `/dev/dri`)
— which would mean revisiting the "portable/remote" default. **If this phase fails
outright, the whole concept needs rethinking — that's exactly why it's first.**

---

## Phase 2 — VNC observation  *(RISK #4)*

**Goal:** a human on the host watches the live editor (and later a running scene).

**Run — `scripts/20_vnc.sh`:** *(candidate — verify)*
```sh
# inside container, alongside the editor from Phase 1:
x11vnc -display :99 -forever -shared -nopw -rfbport 5900 &
```
Container started with `-p 5900:5900`. From the host, connect any VNC viewer to
`localhost:5900`.

**Success criterion:** the host viewer shows the live, updating editor; when a scene
runs (Phase 5/6) you can watch it play.

**What we learn / fallbacks:** confirms the review-flow "live game + interactive
session" assumption is physically possible. Fallback if VNC is flaky: noVNC (browser)
over the same display, or fall back to screenshot/video-only review (Phase 6) — which
would weaken but not kill the review story.

---

## Phase 3 — The MCP bridge comes up  *(RISK #2)*

**Goal:** prove the plugin's WebSocket server (:9500) and the FastMCP HTTP server
(:8000) both come up in the container and bridge to the running editor.

**Build/Run — `scripts/30_mcp_up.sh`:**
- With the editor running + plugin enabled (Phases 0–1), the plugin should auto-start
  its WS server on **:9500**. The plugin starts the Python server via `uvx`/FastMCP on
  **:8000** (`/mcp`). Confirm `uv` is present and that `uvx` can fetch deps (network
  egress, or pre-bake into the image).
- Probes: *(candidate — verify)*
```sh
ss -ltnp | grep -E ':(8000|9500)'           # both listening?
curl -s http://127.0.0.1:8000/mcp           # endpoint responds?
```

**Success criterion:** both ports listen; the `/mcp` endpoint responds; an MCP
`tools/list` handshake returns the plugin's tool set.

**What we learn / fallbacks:** whether the editor-plugin autostart fires headlessly
and whether `uvx` needs network at runtime (if so, pre-install the server into the
image for the real build). If autostart doesn't fire headless, look for a manual
start command / autoload in the plugin.

---

## Phase 4 — Claude Code drives the editor through MCP  *(RISK #3)*

**Goal:** Claude Code, headless, issues MCP ops that **mutate the project on disk**.

**Build/Run — `scripts/40_claude_drive.sh`:** *(candidate — verify)*
- Register the HTTP MCP server with Claude Code:
```sh
claude mcp add --transport http godot http://127.0.0.1:8000/mcp
# or a project .mcp.json with { "mcpServers": { "godot": { "type":"http","url":"http://127.0.0.1:8000/mcp" } } }
```
- Fire a narrow, verifiable instruction:
```sh
claude --dangerously-skip-permissions -p \
  "Using the godot MCP tools: add a child Node2D named 'Marker' to scenes/main.tscn and save the scene."
```

**Success criterion:** `git diff prototype/project/scenes/main.tscn` shows the new node
— i.e. the change is **objectively on disk**, not just claimed. Bonus: watch it happen
live over VNC (Phase 2).

**What we learn / fallbacks:** whether the full Claude→MCP→editor write path works
unattended. If Claude can't see the tools, debug the MCP registration/transport. This
is the phase that proves the agent can *do work*, not just talk.

---

## Phase 5 — Done-gate primitives: run-scene logs + GUT  *(RISK #5)*

**Goal:** a plain shell script decides pass/fail **objectively**, with zero LLM
involvement — the foundation of the whole "script decides" principle.

**Run — `scripts/50_gate.sh`:** *(candidate — verify)*
- Run the scene headless, capture logs + exit code:
```sh
godot --headless --path /project res://scenes/main.tscn --quit-after 120 2>&1 | tee /proof/run.log
echo "exit=$?"
grep -q "<sentinel string from main.gd>" /proof/run.log   # print output captured?
! grep -qiE "ERROR|SCRIPT ERROR" /proof/run.log           # no errors?
```
- Run GUT from CLI with machine-readable results:
```sh
godot --headless -s res://addons/gut/gut_cmdln.gd -gdir=res://test -gexit -gjunit_xml_file=/proof/gut.xml
echo "gut_exit=$?"
```

**Success criterion:** the script reads (a) scene exit code + presence of the sentinel
+ absence of `ERROR`, and (b) GUT's exit code / `gut.xml`, and prints a single
deterministic PASS/FAIL — correctly flipping to FAIL when we deliberately break the
test or the script.

**What we learn / fallbacks:** confirms the objective done-gate is buildable; surfaces
the `--quit-after` / headless-import quirk (godot#77508) and the per-cold-container
import cost (note: pre-build `.godot/import` or commit it for the real system).

---

## Phase 6 — Proof capture + thin end-to-end smoke  *(RISK #6)*

**Goal:** capture proof artifacts, then chain the whole inner loop once.

**Run — `scripts/60_proof_e2e.sh`:** *(candidate — verify)*
- Proof capture off the live display while a scene runs:
```sh
ffmpeg -y -f x11grab -video_size 1280x800 -framerate 15 -i :99 -t 10 /proof/run.mp4
ffmpeg -y -f x11grab -video_size 1280x800 -i :99 -frames:v 1 /proof/shot.png
```
- Thin E2E (GitHub stubbed by the bind-mounted `/project`):
  cold container → Claude makes a small logic change via MCP (Phase 4) → run scene +
  GUT gate (Phase 5) → capture proof → write `/proof/result.txt` with PASS/FAIL.

**Success criterion:** one run produces a code change on disk, a green (or
correctly-red) gate, and proof artifacts in `proof/` — observed live over VNC.

**What we learn / fallbacks:** this is the concept's inner loop, demonstrated. Success
here means the *technical feasibility question is answered yes* and we can confidently
build the real GitHub/ephemeral outer loop from `plan_workflow.md`.

---

## Exit criteria for the whole prototype

The prototype **succeeds** when, in a GPU-less container, we have:

1. The Godot editor rendering under Xvfb (Phase 1). ✅
2. ~~Live VNC observation from the host (Phase 2).~~ **DESCOPED** — live observation is
   not a priority for this feasibility prototype.
3. The MCP bridge up and Claude mutating the project through it (Phases 3–4). ✅
4. An objective, LLM-free done-gate (Phase 5). ✅
5. Proof artifacts + a single chained inner-loop run (Phase 6). ✅

**All in-scope criteria green (4 of 4; VNC descoped). The prototype SUCCEEDS:** in a
GPU-less container, an autonomous Claude→MCP→editor change is objectively judged
red→green by an LLM-free gate. The "godot + hi-godot in a container" feasibility question
is answered **yes** — the real GitHub/ephemeral outer loop in `plan_workflow.md` can be
built on these findings.

Any ❌ is itself a valuable result: it tells us precisely which assumption in
`plan_workflow.md` needs to change *before* we build the real system.

---

## Suggested build order

Phase 0 → **Phase 1 (the gate — stop here if it fails)** → 2 → 3 → 4 → 5 → 6.
There is little point building past Phase 1 until the editor renders headless.

---

## Results log

- **Phase 0 — PASS (2026-06-19).** Guinea-pig project authored under `prototype/project/`
  (`project.godot` pinned to `gl_compatibility`, `scenes/main.tscn`, `scripts/main.gd`
  with a static `add()` + SENTINEL print, `test/test_main.gd` GUT test). Addons GUT
  `9.3.1` and `godot-ai` `v2.7.5` fetched + pinned by the Dockerfile (not enabled yet).
- **Phase 1 — PASS (2026-06-19). The foundational gate is green.** Godot **4.6.3-stable**
  editor boots and *renders* under `Xvfb :99` in a GPU-less Ubuntu 24.04 container.
  Confirmed **genuine software rendering**: `OpenGL API 4.5 … Using Device: Mesa –
  llvmpipe (LLVM 20.1.2) … CPU`. Screenshot `proof/phase1_editor_opengl3.png` shows a
  fully-drawn editor (2D viewport + rulers, FileSystem dock, bottom panel, version
  badge). Only log noise: harmless `Failed loading custom cursor` warnings (no X cursor
  theme under Xvfb). Driver path that worked: `--rendering-driver opengl3` +
  `LIBGL_ALWAYS_SOFTWARE=1`. Vulkan/lavapipe path not needed.
  - *Cosmetic, defer:* editor window not maximized to the Xvfb screen; install a cursor
    theme (`adwaita-icon-theme`/`dmz-cursor-theme`) to silence cursor warnings.
- **Phase 3 — PASS (2026-06-19). The MCP bridge comes up.** With the `godot_ai` plugin
  enabled (added to `[editor_plugins]` at container runtime), the editor running under
  Xvfb auto-started the whole chain: `MCP | using uvx (godot-ai==2.7.5)` → spawned the
  FastMCP server → `MCP | connected to server`. **Both ports listen** (`ss`):
  `127.0.0.1:9500` (WS) and `127.0.0.1:8000` (HTTP `/mcp`), both owned by the
  uvx-spawned `python`. A real **MCP `initialize` + `tools/list`** over streamable-http
  (official `mcp` client) returned **41 tools** (incl. `node_create`, `scene_open`/
  `scene_save`, `session_activate`, `test_run`, `project_run`). Screenshot
  `proof/phase3_editor_opengl3.png` shows the **Godot AI dock with a green "Connected"**
  status. Driver path identical to Phase 1.
  - *Key facts learned:* (a) The headless-disable gate (`--headless`/`display=="headless"`)
    is the reason we must run `--editor` under Xvfb — verified it stays open here.
    (b) `uvx --from godot-ai==2.7.5 godot-ai` **needs PyPI egress at runtime** (~uvx
    cold-start + fetch). For the amnesiac `--rm` system, pre-warm the uv cache or
    pip-install the server into the image. (c) **Versioning is decoupled:** dock/plugin
    report `v2.7.5`, but the running server's `serverInfo.version` is `3.4.2` — connected
    cleanly with no incompatibility warning, but understand this before pinning for real.
- **Phase 4 — PASS (2026-06-19). The agent does work, verified on disk.** Claude Code,
  running fully headless in the container, was given one instruction and the `godot` MCP
  server. The editor log shows the whole chain firing: `Session connected: project@…
  (pid=274, Godot 4.6.3)` → `ListToolsRequest` → `CallToolRequest` ×N →
  `MCP | [recv] create_node({"name":"Marker",…,"type":"Node2D"})`. **Objective verdict
  from `git`-style diff** (`proof/main.diff`): `main.tscn` gained
  `[node name="Marker" type="Node2D" parent="."]` — i.e. the change is **on disk**, not
  just claimed. Auth: a `claude setup-token` OAuth token (Pro sub) injected as
  `CLAUDE_CODE_OAUTH_TOKEN` via `docker run -e` (never baked in).
  - *Key facts learned:* (a) **`--dangerously-skip-permissions` is refused as root** —
    cleared with `IS_SANDBOX=1` (true for an ephemeral `--rm` container). The real system
    must set it or run Claude as non-root. (b) **The editor re-serializes the whole scene
    on save** — the diff also added `uid=`/`unique_id=` and dropped `load_steps`. So
    git-diff verification in the real system sees *editor-normalized* diffs, not surgical
    one-liners; assert on the meaningful node line, not on a minimal diff. (c) The on-wire
    op is `create_node` (dispatch verb) even though the advertised MCP tool is `node_create`.

- **Phase 5 — PASS (2026-06-19). The objective, LLM-free done-gate works AND is honest.**
  A plain shell script (`scripts/50_gate.sh`) decides PASS/FAIL from exit codes + `grep`
  on files, with **zero** Claude/MCP/editor/network involvement. Two ANDed primitives:
  **Gate 1 (run-scene)** — `godot --headless … main.tscn` must exit 0, print the sentinel
  `PROTO_SENTINEL_READY`, and emit no `ERROR`; **Gate 2 (GUT)** — `gut_cmdln.gd -gexit`
  must return exit 0. The host driver (`scripts/03_phase5.sh`) runs it **twice** to prove
  the referee is honest: **clean → PASS (rc 0)**, **deliberately broken → FAIL (rc 1)**.
  Objective proof in the JUnit XML: `gut.clean.xml` = `failures="0" tests="2"`,
  `gut.break.xml` = `failures="1" tests="2"`.
  - *Key facts learned:* (a) **GUT must be ≥ 9.4.0 on Godot 4.6** — 9.3.x declares
    `static var Logger`, which shadows Godot 4.6's new **native `Logger`** class and fails
    to even load (cascading parse errors; the run then hung until our `timeout`). Bumped
    the Dockerfile pin 9.3.1 → **v9.6.0**, which renamed it `GutLogger`. (b) **`-gexit`
    returns a non-zero process exit on test failure** (1 here) — so GUT's exit code alone
    is a sufficient Gate-2 signal; the XML is a bonus artifact. (c) **`tee` masks godot's
    exit code** — recovered via `${PIPESTATUS[0]}`; an OS-level `timeout` is the
    unambiguous safety net (kill → rc 124 → correctly FAILs). (d) Breaking only the *test*
    (not the logic) is the cleanest honesty demo: Gate 1 stays green, Gate 2 flips, and the
    ANDed verdict goes red — proving both gates and the combiner.

- **Phase 6 — PASS (2026-06-19). The whole inner loop runs cold, end-to-end.** One run,
  one fresh container: a task (acceptance test "`main.tscn` must contain a `Marker`
  Node2D") is **injected at runtime** → the *real* Phase 5 gate judges it **RED** → Claude
  satisfies it **via MCP** (adds the Marker, `scene_save`) → the *same* gate re-judges it
  **GREEN** → proof captured → `result.txt` written. **Objective red→green signature:**
  `gate_before rc=1` (`gut.before.xml` `failures="1" tests="3"`) → `gate_after rc=0`
  (`gut.after.xml` `failures="0" tests="3"`), with `[node name="Marker" type="Node2D"
  parent="."]` on disk (`main.diff`). The verdict is derived only from gate exit codes +
  a `grep` on the scene file — the LLM's report is never trusted.
  - *Key facts learned:* (a) **The acceptance test is injected into the ephemeral
    container, never committed** — committing a deliberately-red test would break Phase 5's
    clean run. This models "a task arrives" as a machine-checkable spec. (b) **Reusing the
    unchanged `50_gate.sh` as the before/after judge** is what makes the demo honest: the
    same referee that passes clean code is the one that flips on the agent's work. (c) The
    editor is **torn down before the AFTER gate** to avoid two godot processes contending
    on the project/import cache. (d) **Editor rendering is solid** (29K
    `phase6_editor_*.png`); the *windowed-game* capture (`game_shot.png`/`run.mp4`) is a
    thin, timing-fragile bonus (small/near-blank) — fine, since live observation is
    descoped. For the real system, a reliable gameplay clip would need the scene to stay up
    on a deterministic signal rather than a wall-clock `sleep`.
