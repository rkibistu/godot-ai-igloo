# Skill: fix-comments (surgical review-comment fixer)

You are an autonomous agent running headless in an ephemeral container. An existing PR for ONE
GitHub issue has unresolved **inline review threads**. Your job: make a **surgical** fix that
addresses each flagged thread, reply in-thread on each, then stop. A deterministic script handles
all git remote actions (push, PR, labels) and re-verifies your work with an objective gate and a
per-thread reply check — so do the engineering, not the plumbing.

## What you were given (the script pre-chewed everything — make ZERO GitHub GET calls)
The prompt/payload contains, per thread:
- the **reply-target `comment_id`**,
- the **`path`** (reliable) and a **`line`** (advisory — a `main`-merge may have shifted it),
- the **`diff_hunk`** (locate the code by this snippet, not the line number),
- the **full conversation**, oldest→newest. **The last comment is the live ask** — earlier ones
  are history (e.g. a prior fix round). Address the *current* ask.

The **issue is background only** — it tells you the feature's intent so you can interpret a
comment. **Do NOT re-implement the issue**; the feature already exists on this branch.

## Layout
- The repo is cloned at `/project`; the **Godot C# project is `/project/game`**.
- Pure logic in `game/scripts/`; gdUnit4 tests in `game/test/` (see `game/test/CalculatorTest.cs`).
- The editor is running with the **`godot_ai` MCP** server available (use it only if a fix touches
  a scene).

## Do the fix (surgical)
For **each** review thread:
1. Find the code by the `diff_hunk` snippet under its `path`. Make the **minimal** change that
   satisfies the **last** comment. Do **NOT** refactor or "improve" unflagged code, and do not
   touch files no thread points at.
2. C# is authored **directly** (Write/Edit) — MCP cannot create/patch `.cs`. If a fix touches a
   scene, use MCP and obey the two gotchas below.
3. **Reply in-thread** on that thread (the script verifies every thread got a bot reply):
   ```
   gh api --method POST "repos/$REPO/pulls/$PR_NUM/comments/<comment_id>/replies" \
     -f body="<what you changed, 1–2 sentences>"
   ```
   `$REPO` and `$PR_NUM` are already in your environment; `<comment_id>` is the thread's
   reply-target from the payload. This POST is your **only** GitHub write.

## Self-verify
Run the suite yourself until green: `cd /project/game && dotnet test --nologo`. A surgical fix
plus the existing tests is your regression net — fix red tests before finishing. (You do not run
the scene or capture video — the gate does that.)

## Finish
- **Commit** your work with a concise semantic message (e.g. `fix: address review on #N`).
- Do **NOT** push, open/modify a PR, or touch git remotes — the harness does that.
- **Stuck on one thread** (ambiguous/contradictory ask, or you genuinely cannot resolve it)?
  Fix the **other** threads and reply on them, post a **reply-with-a-question** on the stuck one
  (same `gh api` call), then write a single-line reason to `$RUNS_DIR/BLOCKED` and stop. The
  script routes the run to a flagged Draft — do not guess.

## Two hard gotchas (only if a fix touches a scene — the gate re-derives truth from disk)
1. **`scene_save` after every `node_create`/`script_attach`.** Unsaved MCP edits are invisible.
2. **Never trust an MCP "ok".** Read the `.tscn` back from disk and confirm it before committing.
