# Autonomous Game-Dev Agent Workflow

---
Status: accepted
---

## Context & Decision

We are building an autonomous Godot dev agent (Claude Code + Godot MCP, in Docker)
that implements game-logic issues end-to-end. The governing constraint is that
every step of the workflow must be runnable at an **arbitrary later time,
disconnected from the others** (spec an issue today, run it overnight, review it
another day). This rules out any long-lived process holding state in memory.

The decision: **GitHub is the database and the container is amnesiac and
ephemeral.** All durable state lives in GitHub — Issue (the spec), Branch
(work-in-progress), Pull Request (the merge request), and PR review-comment
threads (the feedback channel). Every run spins up a fresh container, reconstructs
everything it needs from `git` + `gh`, does one unit of work, pushes, and is
destroyed (`--rm`). This is what makes the steps time-independent.

A second principle runs through the whole design: **maximize the deterministic
shell, minimize the LLM surface.** Anything a script can decide reliably with
`git`/`gh` is decided by a script; the agent is invoked only at the transitions
that genuinely need a brain (writing/fixing code), with a narrow, pre-chewed
payload — and never for state transitions or irreversible actions.

## The shape

Two execution contexts:

- **Sandbox (Docker, headless, AFK, autonomous)** — does exactly two jobs:
  *fresh-implement* and *fix-review-comments*. One command, fire and forget.
- **Host (interactive, human-driven)** — does *grill-me* (issue generation) and
  *review* (run the game locally, talk to the agent, produce comments + new
  issues). The "human-in-the-loop implementation" idea from the original vision
  needs **no special infrastructure** — it is just normal interactive Claude Code
  on the host, the same context as review.

Three things get built; everything else is host-native interactive Claude:

1. **grill-me on host** → produces self-contained, testable, logic-oriented
   issues, gated by the `ready-for-agent` label.
2. **AFK sandbox runner** (`agent-run <issue#>`) — the core engineering.
3. **review-setup** (host, flag-driven) — fetch + checkout the branch, launch the
   app, print a review brief, and *optionally* auto-seed an interactive Claude
   session pre-loaded with PR context. Flags choose env-prep-only vs.
   env-prep + seeded session, and whether to launch editor/game.

## Key decisions

- **Mode is inferred, not passed.** `agent-run` takes only an issue identifier.
  A **deterministic entrypoint script** classifies the task state from GitHub and
  routes the work — the human never has to remember "where" a task was:
  - *Fresh* (no PR) → branch from latest `main`, implement.
  - *Fix* (PR exists with a thread where the human spoke last) → address those
    threads on the same branch.
  - *In review* (PR open, no unaddressed threads) → nothing to do, exit.

- **Feedback = PR review-comment threads**, with a dead-simple detection rule:
  a thread **needs agent action iff the last author in it is not the agent**. The
  agent **replies in-thread** after addressing each one (enforced by its skill,
  and verified by the script after the run). The *interactive* review must persist
  its conclusions into GitHub (comments + new issues) so a later disconnected run
  can act on them — the conversation is just how those artifacts get produced.

- **Commit/push split.** The agent makes its own commits (semantic messages) and
  may enrich the PR body / post comments or new issues. The script owns the
  irreversible, outward-facing actions: push, open/update PR, attach artifacts.

- **Agent identity = a dedicated bot GitHub account.** Required for the
  last-author detection rule to be unambiguous, and it makes all commit / comment
  / PR authorship clear. The human reviewer is `rkibistu`. Secrets (`gh` token,
  `ANTHROPIC_API_KEY`) are injected as env vars; the container uses an HTTPS
  remote.

- **One ephemeral container per run**, `--rm`, **detached** (no `--follow`),
  local Docker. Logs are `tee`'d to a **host-mounted directory** (per-run,
  timestamped, named by issue) as the run proceeds, so they survive the
  container's death. One container per run ⇒ runs are parallelizable.

- **Objective done-gate, script-verified.** A run is "done enough to ship" iff
  **GUT tests pass and the target scene runs with no errors in the logs** — judged
  by the script reading results/exit codes, never by asking the LLM. This single
  gate routes every outcome:
  - Pass → push + open a real PR with `Closes #<n>`.
  - Fail / budget exceeded / stuck / merge conflict → push what exists, open a
    **Draft PR**, agent comments exactly where it stopped, script applies a
    `blocked` / `needs-human` label.
  There is a hard wall-clock / cost cap, and **no auto-retry** — every run yields
  a durable GitHub signal (ready PR or flagged Draft PR), and re-firing is always
  a deliberate human action.

- **Label gate is soft.** `agent-run` checks for `ready-for-agent`; if missing it
  prompts the human (present at fire-time) to continue or stop and fix the issue.

- **Branch freshness.** Fresh runs branch from latest `main`. Fix runs `git merge
  origin/main` at run-start: clean → proceed; **conflict → the script prints the
  conflicting files, posts a `merge-conflict, resolve & re-run` PR comment, and
  exits without invoking the agent (zero credits).** The human resolves conflicts
  manually on the host and re-fires. Merge (not rebase) is used so existing PR
  review-thread anchors are preserved; branch clutter is irrelevant because we
  squash-merge.

- **Merge stays in the human's hand.** The human squash-merges (UI or a small
  command); `Closes #<n>` auto-closes the issue. The interactive agent only
  *recommends* shipping — it never performs the merge.

## Consequences

- The system is genuinely resumable: any step can run hours or days after any
  other because GitHub holds all state.
- Correctness of the fix-loop depends on the bot identity being distinct and on
  the agent reliably replying in-thread — hence the script's post-run verification
  of replies.
- Squash-merge keeps `main` clean despite many agent WIP commits; it is also the
  natural hook for a future `proof/`-strip step.

## Deferred (workflow-first; design later)

Proof/artifact format and delivery (a clean seam is reserved — a post-run hook /
`proof/` convention that review-setup can surface) · the Godot↔agent inner loop
(Xvfb / MCP / GUT mechanics, TDD depth) · the governing skills' detailed prompts ·
the Docker image build · parallel-run staleness beyond the merge rule · remote
execution (a clean future swap, made cheap by the ephemeral-container model).

## Considered options (and why rejected)

- **Persistent sandbox / long-lived workspace** — breaks the time-independence
  constraint; state would live in a process that can't survive days-long gaps.
- **Agent infers its own mode / LLM-driven state detection** — wastes tokens and
  is non-deterministic for something `gh`/`git` can decide reliably.
- **Single shared GitHub account with a comment marker convention** — avoids a bot
  account but leaves commit/PR/comment authorship permanently ambiguous and makes
  the last-author detection rule fragile.
- **Agent performs the merge/close on a verbal go-ahead** — puts the most
  irreversible action behind the LLM; the human owns it instead.
- **Rebase fix branches onto `main`** — rewrites pushed history and can orphan PR
  review-thread anchors; we merge instead.
- **Auto-retry on failure** — risks runaway cost with no human in the loop; every
  failure terminates with a durable Draft-PR signal instead.
