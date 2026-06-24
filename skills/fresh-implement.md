# Skill: fresh-implement (autonomous Godot C# dev agent)

You are an autonomous agent running headless in an ephemeral container. You implement ONE
GitHub issue end-to-end, then stop. A deterministic script handles all git remote actions
(push, PR, labels) and re-verifies your work with an objective gate — so do the engineering,
not the plumbing.

## Layout
- The repo is cloned at `/project`; the **Godot C# project is `/project/game`** (run from there).
- Pure logic lives in `game/scripts/` (see `game/scripts/Calculator.cs`).
- Tests live in `game/test/` and use **gdUnit4** (see `game/test/CalculatorTest.cs`).
- The editor is already running with the **`godot_ai` MCP** server available to you.

## Deliverables (all under `game/`)
For target issue **#N** (the number is stated in the prompt; the scene MUST match it):

1. **Feature** — write the C# **directly** (Write/Edit). MCP cannot create/patch C# scripts
   (it is GDScript-only), so you always author `.cs` by hand. Keep it small and focused; do
   not refactor unrelated code.
2. **Test** — a gdUnit4 `[TestSuite]` with `[TestCase]`s that genuinely asserts the new
   behavior (write it to fail first, then make it pass — red→green). Model it on
   `game/test/CalculatorTest.cs` (`using GdUnit4; using static GdUnit4.Assertions;`).
3. **Issue scene** at `res://test/scenes/issue_N.tscn` — prefer building it **via the
   `godot_ai` MCP**:
   - First write `game/test/scenes/IssueN.cs` directly — a `Node2D` (class `IssueN`) that
     draws something visible, exercises the feature, and calls `GetTree().Quit()` after ~5s.
     Model it on `game/test/scenes/Issue0.cs`.
   - Then **`cd /project/game && dotnet build`** so the editor compiles your new `IssueN`
     type (a freshly-written C# class is invisible to MCP `script_attach` until it builds).
   - Then use MCP: `node_create` the root node → `script_attach`
     `res://test/scenes/IssueN.cs` → `scene_save` to `res://test/scenes/issue_N.tscn`.
   - **Fallback (documented work model):** if `script_attach` still errors (the editor did
     not pick up the new type), write `issue_N.tscn` directly as text — model
     `game/test/scenes/issue_0.tscn`, an `ext_resource` Script pointing at
     `res://test/scenes/IssueN.cs` on a `Node2D` root — and note in your commit message that
     MCP could not attach so the scene was hand-written.

## Self-verify
Run the suite yourself until green: `cd /project/game && dotnet test --nologo`. Fix red tests
before finishing. (You do not run the scene or capture video — the gate does that.)

## Finish
- **Commit** your work with a concise semantic message (e.g. `feat: <thing> for #N`).
- Do **NOT** push, open/modify a PR, or touch git remotes — the harness does that.
- If you genuinely cannot proceed (ambiguous/contradictory/missing requirement, or the MCP
  bridge is unusable), write a single-line reason to the file at `$RUNS_DIR/BLOCKED` and stop.

## Two hard gotchas (the gate re-derives truth from disk — your job is to make disk correct)
1. **`scene_save` after every `node_create`/`script_attach`.** MCP edits are not persisted
   until you save; an unsaved scene is invisible to the gate.
2. **Never trust an MCP "ok".** After scene work, read the `.tscn` back from disk (Read) and
   confirm it references your `IssueN.cs` before committing.
