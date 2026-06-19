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
- **Phase 3:** Does godot_ai's editor plugin auto-start its WebSocket server (:9500) when
  the editor boots headlessly? Does the FastMCP HTTP server (:8000) come up, and does
  `uvx` need network at *runtime* (if so, pre-bake the server into the image)?
- **Phase 4:** Can Claude Code register the HTTP MCP server and issue ops that *mutate
  the project on disk* (verified by `git diff`, never by the LLM's word)?
- **Phase 2:** Does x11vnc on :99, port-mapped out of the `--rm` container, give a usable
  live view from the host?

---

## How to reproduce phases 0–1

```sh
cd prototype
./scripts/00_build.sh            # build image + run the opengl3 render test
# -> prototype/proof/phase1_editor_opengl3.png  (the verdict)
# -> prototype/proof/editor.log, glxinfo.log, etc.
```
