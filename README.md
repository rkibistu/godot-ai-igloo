# godot-ai-igloo

An **autonomous game-dev agent** for Godot 4.6.3 (mono / .NET 8) C# projects. It picks up a
GitHub issue, implements it end-to-end in an **ephemeral Docker container**, and opens a pull
request — then, when you leave inline review feedback, a second run makes a surgical fix and
replies in-thread. **GitHub is the single source of truth**; the container is amnesiac and
`--rm`. A deterministic script owns every state transition and objectively verifies the work —
the LLM only writes code, commits, and in-thread replies. It never decides "am I done?".

> Status: **Phases 1–5 complete; Phase 7 (multi-repo harness) built.** The full inner loop runs
> end-to-end, and the harness is now installable globally (`install.sh` → `~/.igloo` + the `igloo`
> dispatcher) and pointable at any Godot C# repo via a committed `.igloo.yml`. Merge stays a manual
> GitHub action (Phase 6). The deterministic Phase-7 plumbing is proven credit-free; the end-to-end
> binary proof against a fresh second repo is the user's to fire. See
> [`plan_implementation.md`](plan_implementation.md) for the phased build + log,
> [`docs/adr/0004`](docs/adr/0004-harness-extraction-integration-model.md) for the integration model,
> and [`CONTEXT.md`](CONTEXT.md) for the canonical glossary.

---

## What it can do

- **Implement an issue (`fresh-implement`).** From an issue body: write the C# feature + a
  gdUnit4 test, build a per-issue **Issue scene** (`res://test/scenes/issue_<n>.tscn`) via the
  `godot_ai` MCP, self-verify with `dotnet test`, commit, and open a PR.
- **Address review feedback (`fix-comments`).** When a PR has an unresolved inline thread whose
  last author isn't the bot, a run gets a rich pre-chewed payload (the diff hunk + full
  conversation per thread, the issue as background), makes a **surgical** fix, replies in-thread,
  and re-verifies.
- **Objectively gate every run (the done-gate).** No LLM in the verdict — see below.
- **Route to a durable GitHub signal.** Ready PR on success; a flagged Draft PR otherwise.
- **Drop you into local review fast (`review-setup`).** Worktree + addon + Godot editor, on the host.

---

## How a run works

```
issue ─▶ classify (no clone) ─▶ prepare branch ─▶ agent writes code ─▶ done-gate ─▶ route result
            (7-row table)        (agent/issue-<n>)   (Claude + MCP)      (objective)   (PR signal)
```

**Classification** (reconstructed from `gh` + `git ls-remote`, zero clone):

| Situation                                             | Class          | Action                              |
|-------------------------------------------------------|----------------|-------------------------------------|
| Issue closed, or PR merged                            | `done`         | nothing                             |
| Open PR + unresolved thread (last author ≠ bot)       | `fix`          | address review feedback             |
| Open **Draft** PR, no actionable thread               | `retry`        | re-run the implementation           |
| Open **Ready** PR, no actionable thread               | `in-review`    | nothing — awaiting the human        |
| PR closed without merging                             | `refuse`       | stop (reopen, or delete the branch) |
| Branch exists, no PR                                  | `resume-fresh` | continue on the branch              |
| No branch, no PR                                      | `fresh`        | implement from scratch              |

**The done-gate** (`scripts/gate.sh`, decided entirely from exit codes + log greps):

1. The Issue scene `res://test/scenes/issue_<n>.tscn` exists.
2. The full gdUnit4 suite passes (`dotnet test`).
3. The Issue scene boots with no runtime errors.
4. A proof video of the Issue scene exists.

**Outcome routing:**

| Result                        | Signal                                            |
|-------------------------------|---------------------------------------------------|
| gate passes                   | PR marked **Ready**, `Closes #<n>`                |
| timeout (wall-clock cap)      | **Draft** + `needs-rerun` label (just re-run)     |
| gate fails / agent blocked    | **Draft** + `blocked` label (needs a human)       |

Runs **never auto-retry**, and **merge stays human and manual**.

---

## Prerequisites

- **Docker** (the agent runs in `godot-ai-igloo:dev`, built locally).
- A **bot GitHub account** with push access to the target repo, distinct from your own. The
  "last author ≠ bot" rule is what triggers the fix loop, so the bot and the human reviewer must
  be different identities. (`gh` CLI for issue/PR ops.)
- A **Claude Code subscription** OAuth token (`claude setup-token`) — required for real agent runs.
- For local review only: a host **Godot 4.6.3 mono** build (the `…_mono_linux_x86_64.zip`); a
  display (`DISPLAY`); 'uv' installed so godot cna start the mcp server for hi-godot

---

## Setup

```bash
# 1. Build the foundation image (Godot 4.6.3 mono + .NET 8 + gdUnit4 + uv + Claude + gh)
bash docker/build.sh                 # -> godot-ai-igloo:dev

# 2. Configure secrets (gitignored; never baked into the image)
cp .env.example .env
#   BOT_GH_TOKEN            = bot account PAT (repo + workflow)        [required]
#   CLAUDE_CODE_OAUTH_TOKEN = from `claude setup-token`               [required for agent runs]
#   GODOT_BIN / GODOT_ZIP   = host Godot for review-setup             [optional]
```

> **Multi-repo (Phase 7).** The per-script commands below self-target the bundled `game/` fixture.
> To drive *any* Godot C# repo, install the harness once (`bash install.sh` → `~/.igloo/harness` +
> the `igloo` dispatcher on your PATH; secrets go in `~/.igloo/.env`), then in the target repo run
> `igloo init` (scaffolds a committed `.igloo.yml` + `.igloo/skills/` + the addon), and use
> `igloo run <issue#>` / `igloo review <issue#>` / `igloo check` / `igloo update`. The mechanical
> contract (repo, `game_subdir`, `godot_version`, `test_command`, Issue-scene paths, gate knobs)
> lives only in `.igloo.yml`. See [`docs/adr/0004`](docs/adr/0004-harness-extraction-integration-model.md).

---

## Usage

### Run the agent on an issue

```bash
bash scripts/agent_run_host.sh <issue#>
```

Spins a fresh `--rm` container, classifies the issue, prepares `agent/issue-<n>`, runs the real
agent (`claude -p` + the Godot editor + `godot_ai` MCP), gates the result, and pushes a PR with
the right signal. Per-run logs land in `runs/<issue>/<timestamp>/` (tee'd out of the container).

The agent only proceeds on issues labeled **`ready-for-agent`** (set `AGENT_RUN_ASSUME_READY=1`
to override). Useful knobs: `AGENT_TIMEOUT` (wall-clock cap, default ~45 min).

### Review a PR locally

```bash
bash scripts/review_setup.sh <issue#>            # worktree + addon + open the Godot editor
bash scripts/review_setup.sh <issue#> --no-launch  # prep only, skip the editor
bash scripts/review_setup.sh <issue#> --remove     # tear the review worktree down
```

Creates an isolated `git worktree` on `agent/issue-<n>` (a sibling dir — never disturbs your
working tree), provisions the gitignored `godot_ai` addon into it, and opens the host Godot
editor. Then **you** drive: review the diff, and **post inline review comments as yourself
(`rkibistu`) in the GitHub UI**. The bot's next Fix run picks them up.

> **Identity matters.** On the dev box the local `gh` session is the *bot* (for testing). In real
> use your session/browser is the *human reviewer*. Review comments must be authored by the human,
> or the fix loop won't fire (it triggers only on threads whose last author ≠ the bot).

### Merge

Manual, by design: click **Squash and merge** in the GitHub UI. The PR body carries
`Closes #<n>`, so the issue auto-closes. (Enable "automatically delete head branches" to keep
merged `agent/issue-*` branches from piling up.)

### End-to-end

```
file an issue (label ready-for-agent)
  └▶ agent_run_host.sh <n>      → Draft→Ready PR
       └▶ review_setup.sh <n>   → review locally, leave inline comments in the UI
            └▶ agent_run_host.sh <n>  → surgical fix + in-thread replies → Ready
                 └▶ Squash-merge in the UI  → issue closes
```

---

## The project contract

Any Godot project the agent works on must satisfy:

- A Godot **C#** project at `game/`, with **gdUnit4** wired for `dotnet test`.
- The **Issue-scene convention**: each issue yields a bootable, self-quitting
  `res://test/scenes/issue_<n>.tscn` the gate can render (model: `game/test/scenes/Issue0.cs`).
- The **`godot_ai` MCP addon** (gitignored; provisioned at runtime from a host mount).
- A toolchain image matching the project's Godot/.NET version.

---

## Scripts

| Script                      | Role                                                                 |
|-----------------------------|----------------------------------------------------------------------|
| `scripts/agent_run_host.sh` | Host launcher: inject the bot secret, run one agent run in a container |
| `scripts/agent_run.sh`      | The spine — classify → branch → invoke agent → gate → route (in-container) |
| `scripts/agent_real.sh`     | The production agent: editor + `godot_ai` MCP bridge + `claude -p`    |
| `scripts/gate.sh`           | The done-gate (4 objective clauses; zero LLM)                        |
| `scripts/bot_init.sh`       | Bot git identity + HTTPS auth (sourced)                              |
| `scripts/review_setup.sh`   | Host: worktree + addon + open the Godot editor for human review      |
| `scripts/run.sh`            | Generic "run a command in the bot container" debug seam              |
| `skills/*.md`               | Governing prompts: `fresh-implement.md`, `fix-comments.md`           |

---

## Design references

- [`CONTEXT.md`](CONTEXT.md) — ubiquitous-language glossary (Done-gate, Issue scene, Feedback thread…).
- [`plan_implementation.md`](plan_implementation.md) — the phased build plan + per-phase build log.
- [`docs/adr/`](docs/adr/) — architecture decisions (0001 GitHub-as-DB / amnesiac container,
  0002 gdUnit4 test contract, 0003 the done-gate).
- [`docs/agents/`](docs/agents/) — issue-tracker, triage-label, and domain-doc conventions.
- [`CLAUDE.md`](CLAUDE.md) — instructions + current-build status for agents working *on* this repo.
