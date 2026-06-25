# Autonomous Game-Dev Agent — Implementation Plan (phased build)

> **NOTE — repo cleanup 2026-06-24 (production-only strip):** the credit-free proof scripts named
> throughout this doc (`phase{2,3,4a,4c,5}_proof.sh`, the `agent_stub`/`agent_fake`/`agent_fix_fake`
> agents, `agent_mcp_smoke.sh`, `binary_proof.sh`, `smoke.sh`) and the dead `mcp_cs_*.sh` were
> **deleted**. Each had PASSED at the time (the build log is an accurate historical record). To
> re-run any regression, restore it: `git checkout fd72b70 -- scripts/<name>.sh`.
>
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
**Split (2026-06-23) into 4a + 4b** to de-risk: the deterministic routing is provable with
a fake agent (no credits), so it lands before the costly LLM integration.

**Phase 4a — Outcome routing + done-gate wiring (deterministic, no LLM). DONE.**
- Insert the post-exit done-gate between the agent step and the PR; route every run to a
  durable signal: Pass→Ready PR, timeout→Draft+`needs-rerun`, gate-red/agent-block→Draft+`blocked`.
- **Binary proof:** a fake agent drives pass/timeout/gate-red/agent-block and the script
  routes each correctly — agent stubbed.

**Phase 4b — Real agent (Claude) + governing skills + MCP + throttle. DONE (minimal, 2026-06-23) — throttle deferred to 4c (see build log + Phase 4c below).**
- Fresh-implement and fix-comments **skills** (the prompts): MCP-first work model + 2 gotchas;
  red→green C# TDD; build the Issue scene + self-drive it; write semantic commits; PR body with
  `Closes #<n>`; reply in-thread on fixes; proactively declare substantive blocks.
- Wire `timeout`-wrapped Claude Code with the fresh/fix payloads (via the `AGENT_CMD` seam) +
  editor/MCP bring-up; **capture the real throttle signature** for `needs-rerun` detection.
- **Binary proof:** one fresh, fully-AFK run on a real `ready-for-agent` issue opens a **Ready
  PR** that passes the gate; one deliberately-underspecified issue terminates in a flagged
  **Draft PR** (correct label + comment).

**Phase 4c — fix-comments / the real fix loop. DONE (2026-06-24) — built & proven credit-free; see build log.**
Job 2 of the sandbox (ADR-0001): respond to PR review comments. The spine already classifies a
`fix` run, merges `main`, builds the threads payload, runs the gate, routes, and verifies replies
(`agent_run.sh`) — but the agent it invokes for `fix` is still the *stub*. 4c builds the agent's
brain for a fix run. **Scope cuts (decided 2026-06-23):** throttle-signature detection **deferred**
(can't force a real throttle on demand); the single paid `claude -p` proof run is the **user's to
fire** — build + prove everything **credit-free** now.
- **Fix-payload design (grilled — the load-bearing part):**
  1. *Surgical* — change only the flagged code; the issue is background to interpret intent,
     never a re-spec; no refactoring/improving unflagged code.
  2. *Script pre-chews everything; the agent makes zero GitHub GET calls* — its only GitHub write
     is the in-thread reply POST.
  3. *Full conversation* per actionable thread (robust to re-fix rounds: the reply-anchor is the
     first comment, the live ask is the last).
  4. *`diff_hunk` + locate-by-snippet* — `path` reliable, `line` advisory (pre-run main-merge shifts it).
  5. *Full issue title+body* as labeled context (`do NOT re-implement`).
  6. *Only actionable threads* (unresolved + last-author≠bot); regression safety = surgical + test gate.
  7. *Agent posts replies via `gh api`* (payload supplies each reply-target `comment_id`); the script verifies coverage.
  8. *Stuck thread → fix the rest, block on it* — reply-with-question + `$RUNS_DIR/BLOCKED` → Draft+blocked.
- **Deliverables:** (0) `agent_run.sh` rich `CLASS=fix` payload via a payload-only GraphQL that
  also fetches each comment's `body`+`diffHunk` (keep `actionable_threads`/`threads.tsv` untouched —
  reply-targeting + verification reuse the proven anchors); (1) `skills/fix-comments.md`;
  (2) `scripts/agent_real.sh` — branch on `CLASS` (fix→`fix-comments.md`) + a `CLAUDE_DRYRUN=1`
  early-exit; (3) `scripts/agent_fix_fake.sh` (credit-free fix agent); (4) `scripts/phase4c_proof.sh`;
  (5) docs. Reuse: reply call `agent_stub.sh:29`; `write_issue_scene` `agent_fake.sh:17`; fix fixture
  + `REVIEWER_GH_TOKEN` from `phase3_proof.sh` row 2; thread-verify `agent_run.sh:283`.
- **Binary proof (credit-free):** a live fixture PR with **two** human-authored inline threads on
  different file:line anchors (via `REVIEWER_GH_TOKEN`; SKIP cleanly without it) → `agent_fix_fake`
  replies to both + makes a gate-safe edit → **real gate** → asserts `CLASS=fix`, rich payload
  (issue + both comment bodies + diff_hunks), `THREADS_VERIFIED=ok`, gate PASS → **Ready**, both
  threads' last author = bot; plus a `CLAUDE_DRYRUN` skill-selection unit. (Stuck-thread→Draft+blocked
  reuses 4a's proven substantive path.) **Paid acceptance run (user fires):** real human thread → real
  agent fixes + replies → Ready.
- **Spine impact:** only the `CLASS=fix` payload block changes — no state-machine/routing change.

### Phase 5 — review-setup (host, environment-prep only) — DONE (2026-06-24)
**Goal:** drop the human into a ready-to-review state fast, local Godot, no sandbox.
**Scope (cut during grilling to env-prep only):** `review_setup.sh <issue#>` makes an isolated
`git worktree` on `agent/issue-<n>`, provisions the gitignored `godot_ai` addon into it, and opens
the local Godot editor — then hands off. The human runs their own AI session (as the reviewer
`rkibistu`, NOT the bot) and posts review comments in the GitHub UI; the bot's Fix run picks them
up. **Cut:** no seeded/automated reviewer, no `REVIEW_CMD` seam, no review brief, no thread-posting
or `REVIEWER_GH_TOKEN` in the shipped script → **no LLM, fully credit-free, no paid acceptance run.**
- **Binary proof** (`scripts/phase5_proof.sh`, host-side, credit-free, no container): a fixture
  issue+branch → `review_setup --no-launch` → asserts worktree on `agent/issue-<n>` + addon
  provisioned + project checked out + idempotent on re-run. Editor-window launch = one-time manual
  eyeball. See build log.

### Phase 6 — agent-merge + deferred
- Tiny `agent-merge` (or just the UI) for the human squash-merge; `Closes #<n>` auto-closes.
- Then tackle the deferred list.

### Phase 7 — harness extraction (multi-repo integration) — BUILT (2026-06-25, deterministic plumbing proven credit-free; see build log)
**Goal:** turn the self-targeting repo into a **global, install-once harness pointed at any
Godot C# repo.** Design basis: **ADR-0004** (the full decision record + the load-bearing
"instructions for future implementations", incl. the rules for correctly adding/changing
`.igloo.yml` fields). Governing requirement: the harness is iterated on a lot, so updating it
across many games must be "update once, every game benefits" — hence one global thing to
update and per-game state the harness never auto-touches.

**Install layout (decided):**
```
~/.igloo/harness/   ← harness clone (git pull to update); bin/igloo dispatcher, scripts/,
                      skills/ (presets), docker/, game/ (fixture + self-test + vendored addon)
~/.igloo/.env       ← GLOBAL secrets (BOT_GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, opt GODOT_BIN)
<game-repo>/.igloo.yml      ← per-game config (committed, self-documenting)
<game-repo>/.igloo/skills/  ← per-game skills, seeded from presets then hand-tuned (committed)
```

**Deliverables:**
1. **`~/.igloo/` install + `bin/igloo` dispatcher** (thin bash): one-line installer (clone +
   symlink `~/.local/bin/igloo` + first `igloo build`). Subcommands: `init`, `run`, `review`,
   `update`, `build`, `check`, `addon install`, `skills diff|update <name>`. Resolves
   `HARNESS_HOME=~/.igloo/harness`, sources `~/.igloo/.env`, walks up from cwd for `.igloo.yml`.
2. **Externalize the hardcoded constants** (today's couplings): `REPO` (`agent_run.sh:23`,
   `review_setup.sh:16`) → auto-detect from `git remote origin` (override via `.igloo.yml`);
   bot login `justfortest1234` (`bot_init.sh`, classifier) → **derive** `gh api user --jq .login`;
   `game/` subdir + scene path → `.igloo.yml`; `IMG` → `godot-ai-igloo:<godot_version>`.
3. **`.igloo.yml` schema + self-documenting template + `igloo check`.** Ship a versioned schema
   (keys, required/optional, default, added-in-version). `check` (and `update`, run in a repo)
   diffs the project's `.igloo.yml` against it and **instructs** on drift — never writes. (See
   ADR-0004 "Instructions for future implementations" for the rules every new field must obey.)
4. **`igloo init`:** scaffold `.igloo.yml` (auto-detect repo/subdir/godot_version) + seed
   `.igloo/skills/` from presets + append `.gitignore` + provision the addon locally;
   **validate-and-instruct** for gdUnit4 (checklist, no `.csproj`/`project.godot` mutation).
5. **Parameterize the gate** (`gate.sh`): read `test_command`, `issue_scene` paths,
   `godot_version`, `gate.proof`, `gate.extra_clauses` from `.igloo.yml` instead of hardcoding;
   run extra-clause hooks (each must exit 0). Gate logic stays global.
6. **Contract injection + skills relocation:** the prompt-builder (`agent_real.sh`) generates the
   mechanical "contract block" from `.igloo.yml` and prepends it to the user prompt; **skills move
   to the game repo's `.igloo/skills/`** (drop the `-v $ROOT/skills:/skills` mount — the container
   gets them via the clone) and **must stay contract-free**.
7. **Addon vendoring flip:** commit `game/addons/godot_ai/` **in the harness fixture only**
   (remove it from the harness `game/.gitignore`); repoint the 3 provisioning sites
   (`agent_run_host.sh:36` mount, `agent_run.sh:218` copy, `review_setup.sh` ADDON_SRC) at
   `$HARNESS_HOME/game/addons/godot_ai`; consumer games keep it gitignored. Keep committing the
   canonical `godot_ai` lines in `project.godot` (no scrub — runtime enable stays a no-op).
8. **Version-tagged local image + `igloo update`:** `igloo build` → `godot-ai-igloo:<godot_version>`
   (Dockerfile `ARG GODOT_VERSION`); `igloo update` = `git -C ~/.igloo/harness pull` + rebuild only
   if image inputs changed + config-drift instruct. Skill refresh stays **explicit/opt-in**
   (`skills diff` / `skills update <name>`); never auto-migrated. No registry.

**Binary proof:** stand up a **second, separate** Godot C# repo (not the harness). `igloo init`
it (only artifacts created: `.igloo.yml` + `.igloo/skills/` + local addon + gitignore lines);
file a `ready-for-agent` issue → **`igloo run <n>` → Ready PR** that passes the gate → **`igloo
review <n>`** opens worktree+editor → human inline comment → **`igloo run <n>` → surgical fix +
in-thread reply → Ready** — **all with zero edits to harness code**, proving the only per-game
surface is `.igloo.yml` + skills. Plus: `igloo check` flags an injected config-drift and `igloo
update` instructs without mutating any project file. (The paid `claude -p` runs are the user's to
fire; the deterministic plumbing — dispatcher, init, schema diff, gate parameterization, addon
provisioning, version-tagged build — is provable credit-free against the fixture.)

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
  throttled OAuth sub — **deferred out of Phase 4c (2026-06-23)**: can't be forced on demand, so
  it awaits a first real throttle; routing to `needs-rerun` is already wired, only the detector is
  open. *(Resolved 2026-06-22: test runner = gdUnit4 via
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

- **Phase 3 — DONE (2026-06-23).** The deterministic state-machine entrypoint
  (`agent-run <issue#>`) is built and proven — classify + plumb, **agent stubbed, zero LLM
  in any transition**. Scripts: `scripts/agent_run.sh` (the spine), `scripts/agent_stub.sh`
  (the Phase-4 `AGENT_CMD` seam), `scripts/agent_run_host.sh` (host launcher, mounts
  `runs/` for tee'd logs), `scripts/phase3_proof.sh` (the binary proof).
  - **Classifier** = pure `classify_from_facts(issue_state, pr_state, pr_is_draft,
    has_actionable_thread, branch_exists)` — the 7-row table, reordered so a
    **closed-unmerged PR is checked before the "no PR" rows**. Facts gathered with **no
    clone**: `gh issue view`, `gh pr list --head agent/issue-<n> --state all`, `git
    ls-remote` for the branch, and a **GraphQL `reviewThreads`** probe. **Actionable
    thread** = NOT resolved AND last comment author ≠ bot (`justfortest1234`).
  - **Lifecycle:** probe → classify → **early-exit** (`done`/`in-review`/`refuse`: no
    clone, zero work) → soft `ready-for-agent` gate (TTY prompt, or
    `AGENT_RUN_ASSUME_READY=1` non-interactive) → **clone fresh** (amnesiac, HTTPS) →
    branch prep (`fresh` branches from `origin/main`; `resume-fresh`/`retry`/`fix` checkout
    `agent/issue-<n>`, never re-branch; `fix` runs `git merge origin/main`, **conflict ⇒
    PR comment + `needs-rerun` + exit, no agent**) → payload (issue body / unresolved
    threads) → `AGENT_CMD` (stub) → **push** → open/update a **Draft PR** (`Closes #<n>`) →
    `fix`-run **thread-reply verification** (`THREADS_VERIFIED=ok`).
  - **Scope boundary (→ Phase 4):** every proceeding run opens a **Draft** PR — there is
    **no done-gate** and no Pass/Transient/Substantive label routing or throttle detection
    yet (those are Phase 4; `AGENT_CMD` is the seam). No Godot/`dotnet` runs in Phase 3, so
    the **import-cache** decision stays deferred.
  - **Binary proof** (`scripts/phase3_proof.sh`): builds **live fixtures per row** on the
    repo (issues + `agent/issue-<n>` branches/commits via the Git-Data + contents API +
    PRs), runs the **full `agent_run.sh` in a fresh `--rm` container** per row (bot, stub),
    and asserts the logged `CLASS` plus side effects (Draft PR for `fresh`/`resume-fresh`;
    `THREADS_VERIFIED=ok` for `fix`). `trap` teardown + a leading sweep ⇒ **zero residue**.
    All 7 rows **PASS live** (verified end-to-end, including row 2 `fix`: human inline
    thread → routes to `fix` → bot in-thread reply → `THREADS_VERIFIED=ok`); the classifier
    is *also* unit-proven hermetically for all 7 rows. **Row 2 (`fix`)** needs a review
    thread whose last author ≠ bot — which the bot **cannot author** — so it is built via
    **`REVIEWER_GH_TOKEN`** (the human reviewer's PAT) in `.env`; without it the proof
    cleanly **SKIPS** row 2 (the other 6 still pass).
  - *Discovery & gotchas:* (a) the host `gh` session is the **bot** (`justfortest1234`),
    not `rkibistu` — hence the `REVIEWER_GH_TOKEN` path for the row-2 human thread, which
    mirrors the real reviewer-vs-bot identity split; (b) `rm -rf`/`git clone` while cwd is
    the `/project` WORKDIR corrupts the cwd → `cd /` first; (c) bind-mounted scripts are
    `0644` → invoke `AGENT_CMD` via `bash`; (d) `gh issue/pr create` ride GitHub's GraphQL
    API, which intermittently **502**s → fixture-setup calls are wrapped in a `retry`, with
    a numeric-issue guard so a blip can't run a row with an empty issue number. New ignore:
    `runs/`.

- **Phase 4a — DONE (2026-06-23).** The post-exit **done-gate + outcome routing** are wired
  into `scripts/agent_run.sh`; every run now ends in the correct durable GitHub signal,
  decided entirely by the script. (Phase 4 was split — 4a is the deterministic half, proven
  with a *fake* agent, no LLM/credits; 4b carries the real Claude + skills + MCP + throttle.)
  - **Lifecycle (steps 5–6):** the agent step is wrapped in `timeout` (`AGENT_TIMEOUT`,
    ~45 min, env-tunable). Outcome decided top-down: **timeout** (rc 124/137) → *transient*;
    else a `${RUNS_DIR}/BLOCKED` marker → *substantive (agent block)*; else run
    **`gate.sh`** → exit 0 = *pass*, non-0 = *substantive (gate)*. Routing: **pass** →
    `git push` → **Ready** PR (`gh pr ready`, `Closes #<n>`, stale flags cleared);
    **transient** → Draft + `needs-rerun` + comment; **substantive** → Draft + `blocked` +
    comment (failing gate clause, or the agent's block reason). Edge: no commits ahead of
    `main` ⇒ post the signal as an **issue** comment (a PR needs a diff). **Invariant
    preserved:** never silent.
  - **Plumbing changes:** `gate.sh` gained a `PROJECT_DIR` knob (the cloned repo's `game/`
    subdir; Phase-1 callers keep the `/project` default) and a `PROOF_DIR` knob (artifacts →
    the per-run dir). `agent_run.sh` writes a tee-independent `${RUNS_DIR}/RESULT`
    (OUTCOME/ROUTED/PR) via a direct redirect so downstream readers don't depend on
    stdout-pipe flushing. `agent_run_host.sh` passes `AGENT_TIMEOUT` through.
  - **Binary proof** (`scripts/phase4a_proof.sh`): a fake agent (`scripts/agent_fake.sh`,
    `FAKE_MODE=PASS|GATE_RED|TIMEOUT|BLOCK`) drives each outcome against live fixtures; the
    **real** gate runs (no LLM). Asserts: PASS → **Ready** PR + `Closes #<n>`; TIMEOUT →
    **Draft** + `needs-rerun` + comment; GATE_RED → **Draft** + `blocked` + failing-clause
    comment; BLOCK → **Draft** + `blocked` + the agent's reason. `trap` teardown ⇒ zero
    residue. **All 4 PASS.**
  - *Gotcha found & fixed:* `gate.sh`'s `fail()` ran `kill -9 "$XVFB_PID"` with `XVFB_PID=0`
    when it failed **before** Xvfb starts (e.g. clause-3 test failure) — and `kill -9 0`
    signals the whole **process group**, which silently killed the parent `agent_run.sh`
    mid-routing. Now guarded (`[ "$XVFB_PID" -gt 0 ]`). Latent since Phase 1, where `gate.sh`
    *was* the container's main process so it only nuked itself.

- **Phase 4b (minimal) — DONE (2026-06-23).** The **real Claude agent** is wired through the
  `AGENT_CMD` seam and proven end-to-end with **one** paid run (Phase 4 was split; this is the
  minimal half — `fix-comments`, throttle-capture, addon-bake, import-cache all deferred).
  - **`scripts/agent_real.sh`** (the production `AGENT_CMD`): brings up Xvfb + `godot --editor`
    + the `godot_ai` MCP bridge (Phase-1 recipe; addon installed from the host-mounted
    `/opt/godot_ai`, read-only), waits for ports 8000/9500 (down ⇒ `BLOCKED`, **before** any
    `claude` call so a failed bring-up costs zero credits), writes an `.mcp.json`, runs
    `claude -p "<payload>" --append-system-prompt <skill> --mcp-config … --dangerously-skip-permissions`,
    then tears the editor + Xvfb down so the gate gets a clean `:99`.
  - **`skills/fresh-implement.md`**: the governing prompt — write C# directly + a gdUnit4
    test (red→green); build the Issue scene **via MCP** (`dotnet build` → `node_create` →
    `script_attach` → `scene_save`, with a hand-written-`.tscn` fallback); `dotnet test`;
    commit (no push/PR); `$RUNS_DIR/BLOCKED` if stuck; the 2 MCP gotchas.
  - **`scripts/agent_run_host.sh`**: defaults `AGENT_CMD=/scripts/agent_real.sh`, mounts
    `/skills` + `/opt/godot_ai`. Proofs still pin `AGENT_CMD` to the stub/fake (credit-free).
  - **`game/project.godot`**: `godot_ai` editor plugin enabled (canonical form; gate-safe —
    the `_mcp_game_helper` autoload loads during the scene render but `binary_proof` stays green).
  - **`scripts/agent_mcp_smoke.sh`** (credit-free de-risk, run before any paid run): brings the
    bridge up, lists **41 MCP tools** via the Phase-1 Python client, confirms `claude` parses the
    HTTP MCP config and sees `godot_ai`. Caught a `docker run` **missing `-i`** (heredoc never
    ran → false PASS) before it could mask anything.
  - **Binary proof (one paid `claude -p` run):** issue **#111** *"add `Calculator.Subtract`"* →
    `fresh` → the agent wrote `Subtract` + 2 gdUnit4 tests + built `issue_111.tscn` **via MCP**
    (uid-based `ext_resource` + `.cs.uid`) → gate **PASS** (4/4, proof video) → **Ready PR #112**
    (`Closes #111`), authored by the bot. Clean diff (5 files; no `project.godot`/addon noise —
    the addon is gitignored, and the agent left the runtime plugin-enable unstaged).
  - *Gotchas found & fixed:* (a) `agent_mcp_smoke` `docker run` lacked `-i` → the `bash -s`
    heredoc ran with empty stdin → false PASS; (b) the `godot_ai` addon is **gitignored**
    (`game/.gitignore`), so it is absent from the fresh clone — provision it from a host
    read-only mount `/opt/godot_ai` (a runtime `git clone` of the external addon was correctly
    **blocked by the sandbox classifier** as untrusted agent-chosen code); (c) enabling the
    plugin makes the editor add an `[autoload]` + `[editor_plugins]` to `project.godot` —
    committed in canonical form so it does not churn at runtime.

- **Phase 4c — DONE (2026-06-24).** The **real fix loop** (`fix-comments`) is built and proven
  **credit-free** — Job 2 of the sandbox (respond to PR review comments) now has a real brain.
  The spine already classified a `fix` run, merged `main`, ran the gate, routed, and verified
  replies; 4c gives the agent the payload + skill to actually do a surgical fix. **Spine impact
  was the `CLASS=fix` payload block only** (no state-machine / routing change), plus one
  infrastructure fix below.
  - **Rich `CLASS=fix` payload** (`agent_run.sh`): a new payload-only GraphQL helper
    `fix_payload_threads` (modeled on `actionable_threads`, same actionable filter) fetches **all**
    comments per thread with `body` + `diffHunk`; jq builds the markdown directly (no system-jq
    dep). `payload.md` now carries: a **surgical** header (change only flagged code; locate by the
    diff_hunk snippet — `path` reliable, `line` advisory after the `main` merge), the **issue
    title+body as background** ("do NOT re-implement"), and per thread the reply-target
    `comment_id` + the **full conversation** (last comment = the live ask). `threads.tsv` (the
    proven reply-targeting + verification anchors) is **untouched**.
  - **`skills/fix-comments.md`** (new): the governing prompt — surgical fix; the script pre-chewed
    everything so the agent makes **zero GitHub GETs**; reply in-thread on each thread via
    `gh api … /replies` (its only GitHub write); self-verify `dotnet test`; commit (no push/PR);
    **stuck → fix the rest + reply-with-question + `$RUNS_DIR/BLOCKED`** (reuses 4a's substantive
    path); the 2 MCP gotchas if a fix touches a scene.
  - **`agent_real.sh`** now branches on `CLASS` (fix → `fix-comments.md` + a "address the review
    comments" prompt; else `fresh-implement.md`) and has a **`CLAUDE_DRYRUN=1` early-exit** that
    prints the selected skill **before** any editor/MCP bring-up or `claude` call (the credit-free
    skill-selection unit).
  - **`agent_fix_fake.sh`** (new): the credit-free fix agent — replies in-thread on every
    `threads.tsv` target (reuses the `agent_stub.sh` reply call) + writes a gate-safe Issue scene
    (reuses `agent_fake.sh`'s `write_issue_scene`) + commits → exercises the **real** gate and the
    spine's reply verification for free.
  - **Spine infra fix (latent 4b regression):** `project.godot` autoloads `_mcp_game_helper` from
    the **gitignored** addon (added in 4b), so **any** post-exit gate run on a fresh clone logged
    "Failed to instantiate an autoload" → the gate's error grep tripped. The real agent installs
    the addon during MCP bring-up, but a fake/stub agent does not. Fix: **`agent_run.sh` provisions
    the addon from `/opt/godot_ai` once after branch-prep**, so the gate is robust for **any**
    `AGENT_CMD`. (Still gitignored → never enters the PR.) `phase4a_proof.sh` updated to mount
    `/opt/godot_ai` (its PASS row's gate would otherwise have failed since 4b).
  - **Binary proof** (`scripts/phase4c_proof.sh`, credit-free): **(A)** a `CLAUDE_DRYRUN`
    skill-selection unit (fix→`fix-comments.md`, fresh→`fresh-implement.md`); **(B)** a live
    fixture PR with **two human-authored inline threads on different files** (via
    `REVIEWER_GH_TOKEN`; SKIPs cleanly without it) → `agent_fix_fake` → asserts `CLASS=fix`, **rich
    payload** (issue + both comment bodies + both diff_hunks), `THREADS_VERIFIED=ok`, **gate
    PASS → Ready PR** (`Closes #n`, `isDraft=false`). **Both checks PASS** (proof run
    `#113`→PR `#114`). Self-cleaning (leading sweep + trap). Regressions re-run green:
    **phase4a 4/4**, **phase3 7/7** (row2-fix exercises the new rich payload).
  - **Deferred (unchanged):** throttle-signature detection (can't force a throttle on demand —
    routing to `needs-rerun` is wired, only the detector is open). **The one paid `claude -p`
    acceptance run is the user's to fire** (real human thread → real agent fixes + replies → Ready).

- **Phase 5 — DONE (2026-06-24).** review-setup — the **first host-side, human-facing** tool —
  is built and proven credit-free. Scope was deliberately **cut during a grilling session to
  environment-prep only** (the human drives the review; the script just stages it).
  - **`scripts/review_setup.sh`** (new, host bash — no container, no LLM): `review_setup.sh
    <issue#> [--no-launch] [--remove]`. Resolves `agent/issue-<n>`, `git fetch origin`, verifies
    the branch exists; makes an **idempotent isolated `git worktree`** (default a sibling dir
    `<repo>-review/issue-<n>`, outside the main tree, reset to the fetched tip with
    `worktree add -B`); **provisions the gitignored `godot_ai` addon into the worktree** (else the
    editor trips the same `_mcp_game_helper` autoload error the gate hit in 4c); then opens the
    **host Godot editor** (`GODOT_BIN` from `.env`, else extracts the 4.6.3-mono zip once into the
    gitignored `.tools/godot/`). `--remove` tears the worktree + local branch down. Repo-specific
    values live in **one top block** for the Phase-7 `--repo` lift.
  - **Decisions (grilled):** the bot is the local `gh` identity only because we're testing —
    in real use the human's session is `rkibistu`, and the bot lives only in the container, so
    **identity is the human's concern at session-start, not the script's.** Therefore: **no seeded
    reviewer / `REVIEW_CMD` / `skills/review.md`, no review brief, no thread-posting, no
    `REVIEWER_GH_TOKEN`** in the shipped script. Worktree (not in-place checkout) so the dev's
    working tree is never disturbed.
  - **Binary proof** (`scripts/phase5_proof.sh`, host-side, **credit-free, no container**): fixture
    issue + remote `agent/issue-<n>` (from `main`, so `game/` exists) + Draft PR →
    `review_setup --no-launch` (×2 for idempotency) → asserts the worktree HEAD is `agent/issue-<n>`,
    `game/addons/godot_ai/` is present, `game/project.godot` checked out. **PASS** (fixture
    `#136`). Self-cleaning (sweep + trap; removes worktree, local branch, remote branch, issue —
    zero residue). The **Godot editor window opening is a one-time manual eyeball** (a GUI can't be
    asserted headlessly): `bash scripts/review_setup.sh <real-issue#>`.
  - **No spine change** → regressions (phase3/4a/4c) logically untouched. **No paid acceptance run**
    (Phase 5 spends no credits).
  - **Roadmap:** **Phase 6** = merge (likely just the human clicking Squash-merge in the GitHub UI;
    `Closes #n` auto-closes) → **Phase 7** = harness extraction (`--repo` + a thin `.igloo.yml`),
    the decided-but-deferred "shared harness pointed at any repo" integration model, done after
    Phase 5 so it captures Phase 5's host couplings too.

- **Phase 7 — BUILT (2026-06-25), deterministic plumbing proven credit-free.** The self-targeting
  repo is now a global, install-once harness pointable at any Godot C# repo (design: ADR-0004).
  Built in 5 staged slices, each proven on the bundled `game/` fixture before the next:
  - **Stage 0 — config foundation.** `scripts/lib/config.sh` (`cfg_get`/`cfg_list`/`cfg_subst` over
    **`yq`**, mikefarah; resolves `$IGLOO_YQ`→PATH→`~/.igloo/bin`→`/usr/local/bin`; tolerant of a
    missing `.igloo.yml` → literal defaults), `schema/igloo.schema.yml` (versioned key list:
    required/default/added_in), self-documenting `templates/igloo.yml.tmpl`, the fixture's own
    `/.igloo.yml`, and `yq` baked into the image (`docker/Dockerfile`). *Proof:* host + in-container
    readers resolve scalars/nested/lists/defaults + `{n}` substitution.
  - **Stage 1 — externalize constants.** `REPO`→`IGLOO_REPO` (host-resolved pre-clone; auto-detect
    from `git remote origin`); bot login/email **derived** `gh api user` (drops hardcoded
    `justfortest1234`/`142491623` — verified to reproduce them exactly); `game_subdir` from config;
    `IMG`→`godot-ai-igloo:<godot_version>` (`docker/build.sh` now tags by version + `:dev` alias);
    `review_setup` repo/subdir from config + git ops pointable. *Proof:* host-side resolution +
    mocked-`gh` identity derivation, side-effect-free.
  - **Stage 2 — parameterize the gate.** `gate.sh` reads `test_command`/`issue_scene.*`/`gate.proof`/
    `gate.extra_clauses` from `.igloo.yml`; runs extra-clause hooks (each must exit 0); logic stays
    global. *Proof:* fixture gate **PASS 4/4** reading from config + a passing extra-clause, and the
    fail-path proven (a hook exiting 1 fails the gate).
  - **Stage 3 — contract injection + skills relocation.** `agent_real.sh` generates the mechanical
    **contract block** from `.igloo.yml` (same source the gate reads → cannot drift); skills moved to
    the game repo's `.igloo/skills/` (the `-v skills` mount dropped — they arrive via the clone).
    *Proof:* `CLAUDE_DRYRUN` resolves per-class skill + renders the contract with `{n}` substituted.
  - **Stage 4 — addon vendoring flip.** `game/addons/godot_ai/` is now **committed in the harness
    fixture only** (un-ignored; 223 files staged); consumer games keep it gitignored; the 3
    provisioning sites point at `$HARNESS_HOME/game/addons/godot_ai`; canonical `project.godot` lines
    stay committed (no scrub). *Proof:* `check-ignore` + index tracking + `igloo init` gitignores it
    in a consumer game.
  - **Stage 5 — dispatcher + install + lifecycle.** `bin/igloo` (run/review/init/check/build/update/
    addon/skills) + `install.sh` (clone-or-`--dev`-symlink `~/.igloo/harness`, fetch `yq`, symlink
    `~/.local/bin/igloo`, scaffold `~/.igloo/.env`, first build). *Proof (against a throwaway second
    repo, no GitHub):* `init` (auto-detect repo/subdir, scaffold config + skills + gitignore +
    addon, gdUnit4 validate-and-instruct, zero project mutation); `check` (ok; injected drift →
    rc 1); `skills diff`; `addon install`; **`update` writes NO project file** (checksum-verified);
    `install.sh --dev --no-build` in a sandboxed `HOME`. (Root `.gitignore` `**/bin/` negated for
    the dispatcher dir.)
  - **Open (the user's to fire — GitHub side effects + paid credits):** the **binary proof** —
    `igloo init` a real second Godot C# repo and drive `run → review → fix → check/update`
    end-to-end with zero harness-code edits (deterministic parts credit-free with a fake
    `AGENT_CMD`; the `claude -p` runs are paid). Restore a fake agent via
    `git checkout fd72b70 -- scripts/<name>.sh`.
