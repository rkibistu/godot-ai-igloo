# Autonomous Game-Dev Agent — Implementation Plan (phased build)

> Durable record of the design/grilling session of **2026-06-22**. This is the phased
> **build** plan for the real system. It is self-contained, but its design basis is:
> `ArhitectureConcept`, `plan_workflow.md` (the prior workflow design), `CONTEXT.md`
> (glossary), `docs/adr/0001..0003`, and the feasibility findings in
> `plan_prototype.md` on branch `prototype_v1`.
>
> **The prototype is reference-only.** Its inner-loop code proved feasibility on
> GDScript; it is a findings source and a list of gotchas, **not** a foundation to
> lift. The real inner loop is re-designed, re-implemented, and re-verified.

---

## Why the phases are re-cut (vs the prototype's six)

The prototype's six phases were cut by **inner-loop technical risk** (rendering → MCP →
drive → gate → proof) — all now green. The real system's unproven, load-bearing part is
the **outer loop** (GitHub state machine, bot identity, secrets, fix/review loop,
ephemeral `--rm` lifecycle), which the prototype *faked* with a local bind-mount. So we
keep the prototype's **methodology** (incremental; every phase ends in a binary,
demonstrable proof) but **re-cut the phases around the outer loop**, with the inner loop
rebuilt-and-revalidated up front (it also has to absorb the C# pivot).

---

## Foundational principles (carry from ADR-0001)

- **GitHub is the database; the container is amnesiac and `--rm`.** All durable state is
  in GitHub (Issue, Branch `agent/issue-<n>`, PR, inline review threads). Each run is a
  fresh container that reconstructs from `git`+`gh`, does one unit of work, pushes, dies.
- **Maximize the deterministic shell, minimize the LLM surface.** Scripts decide; the
  agent is invoked only to write/fix code. **Never trust the LLM for a state transition.**
- **The script decides; the agent writes code (+ its own commits / in-thread replies).**
  Irreversible/outward-facing actions (push, PR, merge) stay in deterministic code or in
  the human's hand.

---

## Decisions settled this session (delta over `plan_workflow.md`)

| Area | Decision | Ref |
|---|---|---|
| **Scripting language** | **C#** (reverses the prototype's GDScript). Image needs the .NET Godot build + .NET SDK + a compile step. | ADR-0002 |
| **Test runner** | **gdUnit4** (chosen 2026-06-22), behind a stable `run-tests` contract (one command → exit 0/non-0) so it stays swappable. | ADR-0002, [[Test suite]] |
| **Claude auth** | **`CLAUDE_CODE_OAUTH_TOKEN`** (subscription), not `ANTHROPIC_API_KEY`. ⇒ cap is **wall-clock only**; usage-throttle is an expected failure mode; heavy parallelism is capacity-bounded by one subscription. | — |
| **Done-gate (generalized)** | 4 objective clauses: Issue scene exists; Issue scene boots clean (weak smoke); full test suite passes; proof video exists. | ADR-0003 |
| **Issue scene** | Mandatory per issue at `res://test/scenes/issue_<n>.tscn`. Demo + boot-smoke + proof vehicle + reviewer hand-off. **Not** the behavioral gate (the test suite is). Self-drives the feature for ~N s then quits deterministically. | ADR-0003 |
| **Proof** | Video **existence** is gated; format/storage/PR-attach/merge-strip deferred. Script captures (ffmpeg off the Xvfb display while the Issue scene runs with rendering); agent makes it worth capturing. | ADR-0003 |
| **Failure taxonomy** | **Transient** (cap/throttle/merge-conflict → `needs-rerun`) vs **Substantive** (`blocked`). | [[Transient failure]], [[Substantive block]] |
| **Who posts the signal** | Whoever detects it posts it. Script has objective facts for timeout/throttle/gate-fail; agent posts only proactive blocks (while alive) + in-thread fix replies. Gate runs **post-exit**. | — |
| **Feedback channel** | **Inline review threads only** (last author ≠ bot). Non-line feedback → **new issue**. Conversation-tab comments + review summaries are **ignored**. Host review agent opens inline threads via `gh api`, authored as the human. | [[Feedback thread]] |
| **Agent work model** | **MCP for everything it supports**; never hand-edit Godot files unless MCP can't — then hand-edit **and flag in a PR comment** for later human verification. **Script files** are always direct edits. Two gotchas baked into the skill: `scene_save` after every `node_create`; never trust MCP's "ok" (gate re-derives truth from disk). | — |
| **State machine** | Full classification table below (incl. error/edge states). | this doc |
| **Run bounding** | `timeout`-wrapped agent step (~45 min) + container ceiling (~60 min), env-tunable. Throttle detected by inspecting the agent's captured output/exit (signature TBD Phase 4). | this doc |

---

## The state-machine classification table (deterministic, no LLM)

Classifier = pure function of {issue state, PR existence/state, inline-thread presence,
branch existence}. **Draft-vs-Ready is a signal** (Draft = "not done, keep working";
Ready = "done, awaiting human"). The `needs-rerun`/`blocked` labels are **human triage
hints, not classifier inputs.** Evaluated top-down, first match wins:

| # | GitHub state | Class | Action |
|---|---|---|---|
| 1 | Issue **closed** (merged/wontfix) | Done / refuse | Exit "already closed", zero tokens. |
| 2 | Open PR with **≥1 inline thread, last author ≠ bot** | **Fix** | Merge `main` → address those threads (Draft or Ready). |
| 3 | Open **Ready** PR, no such thread | **In-review** | Nothing to do — exit, zero tokens. |
| 4 | Open **Draft** PR, no such thread | **Retry/resume** | Continue implementing on the branch + re-gate. (This is a re-fire of a `needs-rerun`/`blocked` Draft; the human's re-fire is the trigger — no auto-retry.) |
| 5 | **No PR, branch exists** | **Resume-fresh** | Checkout branch, continue, open PR. **Never re-branch / discard pushed work.** |
| 6 | No PR, no branch, issue open | **Fresh** | Branch from latest `main`, implement. |
| 7 | **Closed-unmerged** PR exists | **Refuse** | Exit "PR #x closed without merging; reopen or delete the branch to start fresh." |

---

## Run lifecycle (one `agent-run <issue#>` invocation)

1. **Cold start, classify** (table above) from `gh`/`git`. Soft `ready-for-agent` gate:
   if missing, prompt the human (present at fire time) to continue or stop.
2. **Prepare branch.** Fresh → branch from `main`. Fix/retry/resume → checkout branch;
   fix runs `git merge origin/main` (merge, not rebase) — **conflict ⇒ no agent**: print
   conflicting files, post `merge-conflict, resolve & re-run` PR comment, exit (`needs-rerun`).
3. **Gather payload** (script): issue body (fresh) or the exact unresolved threads (fix).
4. **Invoke agent** under `timeout` (≈45 min): editor up under Xvfb (for MCP scene work) +
   direct C# edits; agent runs tests itself to self-guide red→green; commits; tears down
   editor. Output `tee`'d to a host-mounted, per-run, timestamped log.
5. **Done-gate** (script, post-exit, 4 clauses of ADR-0003), incl. building the C#
   assembly and the rendered Issue-scene run + ffmpeg proof capture.
6. **Route the outcome** (script owns push + PR):
   - **Pass** → push → open/refresh **Ready** PR with `Closes #<n>`.
   - **Transient** (timeout/throttle/conflict) → push what exists → **Draft** PR + `needs-rerun`, **script-posted** comment naming the cause.
   - **Substantive** (gate red / agent proactively blocked) → push → **Draft** PR + `blocked`; comment from whoever detected it (script names the failing gate clause; agent names ambiguity/missing asset).
   - **Invariant:** every run yields a durable GitHub signal — Ready PR or flagged Draft PR. Never silent.
7. Container destroyed (`--rm`).

---

## The phases (each ends in a binary proof)

### Phase 1 — Inner loop rebuilt + C# stack validated
**Goal:** a clean, structured image and inner loop that work **for C#** (the prototype only
proved GDScript). Test runner = **gdUnit4** (decided).
- Build the image: **.NET/Mono Godot build** + **.NET SDK** + Xvfb + mesa (llvmpipe:
  `--rendering-driver opengl3` + `LIBGL_ALWAYS_SOFTWARE=1`) + ffmpeg + Claude Code + `gh`/`git`
  + **MCP server pre-baked** (no PyPI egress at runtime — prototype gotcha) + pre-built
  `.godot/import` cache + **gdUnit4** (editor addon + C# NuGet).
- Re-implement (don't lift) the inner-loop primitives: editor-up-under-Xvfb, the `run-tests`
  contract (exit 0/non-0), the Issue-scene rendered run + ffmpeg capture, the 4-clause gate.
- Validate end-to-end on C#: build step, **gdUnit4 running C# tests headless**, and
  **whether `godot_ai` MCP can create/attach `.cs` scripts** (if not, the hand-edit-and-flag
  rule applies).
- **Binary proof:** in a fresh container, a tiny C# change → the 4-clause gate flips
  **red→green** with zero LLM in the verdict; gdUnit4 confirmed running C# tests headless.

### Phase 2 — Bot account + secrets injection
**Goal:** the distinct identity the fix-loop detection depends on.
- Create the bot GitHub account, give it push access, mint a token; HTTPS remote in-container.
- Inject `bot GH token` + `CLAUDE_CODE_OAUTH_TOKEN` via `docker run -e` (never baked).
  Handle root + `--dangerously-skip-permissions` (set `IS_SANDBOX=1` or run non-root —
  prototype gotcha).
- **Binary proof:** from inside a container, the bot pushes a branch and opens a PR
  authored as the **bot** (≠ `rkibistu`).

### Phase 3 — Deterministic state-machine entrypoint (no LLM)
**Goal:** the real heart the prototype faked — classify + plumb, zero agent.
- Implement the 7-row classifier from `gh`/`git`; branch handling; fix-run `main` merge with
  conflict→exit; `tee` logging to host mount; soft label-gate prompt; push + open/update PR;
  post-run verification that each targeted thread got a bot reply.
- **Binary proof:** drive every row of the table with hand-made GitHub fixtures (issue/branch/
  PR/thread states) and assert the script routes each correctly — **agent stubbed out**.

### Phase 4 — Agent invocation + governing skills + outcome routing
**Goal:** wire the headless agent into the spine and route real outcomes.
- Fresh-implement and fix-comments **skills** (the prompts): MCP-first work model + 2 gotchas;
  red→green C# TDD; build the Issue scene + self-drive it; write semantic commits; PR body with
  `Closes #<n>`; reply in-thread on fixes; proactively declare substantive blocks.
- Wire `timeout`-wrapped Claude Code with the fresh/fix payloads; the post-exit gate; the
  Pass/Transient/Substantive routing + labels; **capture the real throttle signature** for
  `needs-rerun` detection.
- **Binary proof:** one fresh, fully-AFK run on a real `ready-for-agent` issue opens a **Ready
  PR** that passes the gate; one deliberately-underspecified issue terminates in a flagged
  **Draft PR** (correct label + comment).

### Phase 5 — review-setup (host, flag-driven)
**Goal:** drop the human into a ready-to-review state fast, local Godot, no sandbox.
- Flags: `git fetch`+checkout the branch; print a review brief (diff summary + unresolved
  threads); launch editor/game; optionally seed an interactive Claude session pre-loaded with
  PR context. (The host review agent opens inline threads via `gh api`, authored as the human.)
- **Binary proof:** one command takes a PR# to a running game + a printed brief; a seeded
  session posts an inline review thread that a subsequent **Fix** run picks up.

### Phase 6 — agent-merge + deferred
- Tiny `agent-merge` (or just the UI) for the human squash-merge; `Closes #<n>` auto-closes.
- Then tackle the deferred list.

---

## Deferred (leave clean seams; do not let the flow depend on these)

- **Old-Issue-scene regression net** — re-running all accumulated Issue scenes as a boot/load
  smoke (you'll handle later). For now only the current Issue scene is booted.
- **Proof artifact format/storage/PR-attach/merge-strip** — existence is gated; the rest is open.
- **Deeper TDD depth** in the agent skill.
- **Parallel-run staleness** beyond the fix-run `main`-merge rule.
- **Remote/cloud execution** — a clean future swap (ephemeral model makes it cheap).

## Open empirical items (resolve during the named phase)

- **import-cache pre-build** (Phase 1) · **throttle signature** of `claude -p` on a
  throttled OAuth sub (Phase 4). *(Resolved 2026-06-22: test runner = gdUnit4 via
  `dotnet test`; MCP `script_attach` binds `.cs` to nodes, but `script_create`/`patch`/
  `test_run` are GDScript-only → the agent writes `.cs` directly.)*

## Invariants to preserve

- GitHub is the only source of truth; container is amnesiac + `--rm`.
- The script decides; the agent only writes code (+ commits / in-thread replies).
- Never trust the agent's self-assessment for a transition — verify with tests/exit codes.
- Every run yields a durable GitHub result — Ready PR or flagged Draft PR.
- No auto-retry. Merge + conflict-resolution stay human and manual.
- The agent is a distinct **bot** identity; "last author ≠ bot" drives the fix loop.

---

## Build log

- **Phase 1 — DONE (2026-06-22).** The C# inner loop is validated end-to-end in a
  GPU-less container. Foundation image (`docker/Dockerfile`: Ubuntu 24.04 + Godot 4.6.3
  **mono** + .NET 8 + Xvfb/mesa + uv + Claude + gh) builds clean (~2.5 GB). Proven:
  - **Mono editor renders** under Xvfb via Mesa **llvmpipe** (`--rendering-driver opengl3`
    + `LIBGL_ALWAYS_SOFTWARE=1`).
  - **gdUnit4 C# tests run headless** via `dotnet test` — pinned `gdUnit4.api` 5.0.0 +
    `gdUnit4.test.adapter` 3.0.0 + `Microsoft.NET.Test.Sdk` 17.14.1, `Godot.NET.Sdk`
    4.6.3; honest red↔green exit codes.
  - **MCP drives C# scenes:** `session_activate → node_create → script_attach(.cs) →
    scene_save` works; `script_create`/`patch`/`test_run` are GDScript-only → the agent
    writes `.cs` **directly** (per the work model).
  - **4-clause done-gate** (`scripts/gate.sh`) passes all clauses and captures a
    **non-blank** proof video + still of a deterministic-quit Issue scene
    (`game/test/scenes/issue_0.tscn`).
  - **Binary proof** (`scripts/binary_proof.sh`): a tiny C# change flips the gate
    **red (rc=1) → green (rc=0)** in fresh `--rm` containers, judged only by exit codes.
  - *Hygiene:* `--audio-driver Dummy` silences ALSA noise; gate greps script/exception
    markers (not generic engine `ERROR:`); editor teardown uses `kill -9`/graceful MCP
    quit to avoid the software-GL SIGSEGV core dump.
  - *Deferred to lifecycle phases (2/3):* image **finalization**. Baking `game/` is wrong
    for the amnesiac model (the container clones the repo fresh per run); what to bake
    (godot_ai addon, uv prewarm) vs clone, and the **import-cache strategy** (commit
    `.godot/` vs rebuild per run), is a Phase-2/3 decision.

- **Phase 2 — DONE (2026-06-23).** The bot's distinct GitHub identity + runtime
  secret-injection path are wired and proven. Bot account `justfortest1234` (id
  `142491623`) has push access to `rkibistu/godot-ai-igloo`; human reviewer is `rkibistu`.
  - **Secrets via `docker run -e`, never baked.** Host `scripts/run.sh` loads a gitignored
    `.env` (`.env.example` is the template) and maps `BOT_GH_TOKEN` → container `GH_TOKEN`
    (+ a `CLAUDE_CODE_OAUTH_TOKEN` slot, empty until Phase 4) + `IS_SANDBOX=1`.
  - **In-container identity** (`scripts/bot_init.sh`, sourced): sets the bot's git
    user.name/email (GitHub noreply `142491623+justfortest1234@users.noreply.github.com`,
    so commits attribute to the bot) and runs `gh auth setup-git` so HTTPS clone/push
    authenticate as the bot via gh's credential helper (no SSH key in-container).
  - **`IS_SANDBOX=1` baked** into the image (`docker/Dockerfile`) for root + Claude
    `--dangerously-skip-permissions`; `bot_init.sh` re-exports it for non-rebuilt images.
  - **Secret-wiring is opt-in:** the Phase 1 gate/smoke/binary_proof (no secrets,
    bind-mount `game/`) are untouched — `scripts/binary_proof.sh` still flips red→green
    after the image rebuild.
  - **Binary proof** (`scripts/phase2_proof.sh`): a fresh `--rm` container clones over
    HTTPS → pushes `phase2-proof-<ts>` → opens a **Draft PR authored as `justfortest1234`
    (≠ `rkibistu`)** with the bot noreply commit email → then closes the PR + deletes the
    branch (self-cleaning, re-runnable). Verified PR author + commit email; cleanup leaves
    zero residue.
  - *Gotcha found & fixed:* a scratch file under `proof/` was swallowed by `.gitignore` →
    empty commit → "no commits between" PR failure; switched to `git commit --allow-empty`
    (a proof only needs a bot-authored commit, not file content).
