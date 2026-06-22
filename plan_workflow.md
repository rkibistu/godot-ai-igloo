# Autonomous Game Dev Agent — Implementation Plan

> **Refined / partly superseded (2026-06-22).** A later grilling session updated several
> decisions below — see `plan_implementation.md` (the phased build plan) and
> `docs/adr/0002` & `0003`. Notably: **C#**, not GDScript; the **OAuth subscription
> token**, not `ANTHROPIC_API_KEY`; and the **generalized 4-clause done-gate**. Treat
> this file as the historical design record; `plan_implementation.md` is authoritative
> for the build.
>
> This plan is the durable record of a design/grilling session. It is written to be
> self-contained: a fresh implementation session with no memory of that conversation
> should be able to build from it. The original concept lives in `ArhitectureConcept`.

## Goal

A sandbox-based autonomous Godot dev agent with an **async, resumable** workflow.
You generate issues on the host, fire a fully-AFK sandbox run against one issue
(it opens a PR), review it (live game + interactive AI session), and re-fire the
sandbox to address review comments on the same branch — looping until you merge.

**The headline constraint (everything bends to this):** every step must be runnable
at an arbitrary later time, disconnected from the others. Step 1 today, step 2
overnight, step 3 another day. No long-lived process may hold state in memory.

Repo: `rkibistu/godot-ai-igloo` (you are `rkibistu`). Stack from the concept:
Godot 4.x, hi-godot MCP plugin, Claude Code (`--dangerously-skip-permissions`),
Xvfb (+ optional x11vnc), Docker, GUT for tests.

---

## Architectural keystone — GitHub is the database

State lives **entirely in GitHub**, never in the container:

| GitHub artifact | Role |
|---|---|
| Issue | the task spec |
| Branch (`agent/issue-<n>`) | work in progress |
| Pull request | the merge request |
| PR review-comment threads | the feedback channel |
| `proof/` (deferred) | evidence artifacts |

The container is **amnesiac and ephemeral**: spun up fresh per invocation, it
reconstructs everything from `git` + `gh`, does its work, pushes, and is destroyed
(`docker run --rm`). This is precisely what makes the steps time-independent — you
never have to remember "where" a task was; the agent re-derives that from GitHub.

### Guiding principle — maximize the deterministic shell, minimize the LLM surface

The LLM is expensive, non-deterministic, and the part most likely to misbehave.
Anything a script can decide reliably with `git`/`gh`, a script **must** decide.
The agent is invoked only at transitions that genuinely need a brain (writing/
fixing code), and only after the script has pre-chewed a narrow payload for it.
**Never trust the LLM's self-assessment for a state transition** — verify objectively.

---

## The three things we build

Everything else (the "human-in-the-loop implementation" mode, and the review
conversation itself) is **just normal interactive Claude Code on the host** — no
infrastructure required.

1. **grill-me on host** — produces issues (largely an existing skill). See *Entry contract*.
2. **AFK sandbox runner** (`agent-run`) — the real engineering. See *The sandbox runner*.
3. **review-setup** (host, flag-driven) — fast review staging. See *review-setup*.

---

## Component: the sandbox runner (`agent-run <issue#>`)

One host command. One ephemeral container per run. The container's entrypoint is a
**deterministic state-machine script** that does all the plumbing and invokes the
agent only when needed.

### Invocation & lifecycle
- `agent-run <issue#>` — single arg, the issue number.
- **Soft label gate:** if the issue is not labeled `ready-for-agent`, prompt the
  human: *"this isn't ready-for-agent — continue anyway, or stop and fix it?"*
  (The human is at the keyboard at fire-time, so an interactive prompt is fine.)
  Continue → proceed; stop → exit so they can improve the issue.
- `docker run --rm` a **fresh container** from a prebuilt image. One container per
  run ⇒ multiple issues can be fired in parallel (each its own branch).
- **Detached** by default (no `--follow`). You fire it and walk away (overnight).
- **Logs are mandatory and must survive the container.** Since `--rm` destroys the
  container, `tee` all output to a **host-mounted log dir** *as it runs*, per-run,
  timestamped, named by issue.
- Local Docker for now. Remote/cloud execution is a clean future swap (the
  ephemeral model makes it cheap).

### Secrets & identity
- Inject a **GitHub token** + `ANTHROPIC_API_KEY` as env vars. Use an **HTTPS
  remote** inside the container (not your SSH key).
- The agent acts as a **dedicated bot GitHub account** (a machine user with its own
  token), distinct from you (`rkibistu`). This is **required**, not cosmetic: the
  feedback detection rule (below) is "last author in thread ≠ agent," which only
  works if the agent's identity is unambiguously different from yours. The bot also
  makes all commit/comment/PR authorship clear and auditable.

### The state machine (script classifies, then dispatches)
On every cold start the script reads GitHub and infers the job — the human never
passes a "mode."

| State | Detected by | Action |
|---|---|---|
| **Fresh** | issue exists, no branch/PR | branch from latest `main`, implement |
| **Fix** | PR open, ≥1 thread where the *last author is you* | merge `main`, address those threads |
| **In review** | PR open, no thread where you spoke last | nothing to do — exit, zero tokens |
| **Done** | (terminal — see *Merge & close*) | n/a |

**Boundary — who does what:**
- **Script (deterministic):** classify state; clone/fetch; create/checkout branch
  (`agent/issue-<n>`); gather payload into a prompt file (issue body for fresh; the
  *exact* unresolved threads for fix); decide whether to invoke the agent at all;
  after the agent finishes — push, open/update PR, apply labels, (future) attach proof.
- **Agent (LLM):** implement / address comments; run scenes + GUT, fix failures;
  write commit messages; write the PR title/body; **reply in-thread** to each review
  comment it addresses; may add extra PR/issue comments for context.
- **Agent commits; script pushes and opens the PR.** Irreversible/outward-facing
  actions (push, PR) stay in deterministic, auditable code.

### Fresh run
1. Branch `agent/issue-<n>` from latest `main`.
2. Agent implements from the issue body; runs scenes + GUT; commits.
3. Done-gate (below) → real PR or Draft PR.
4. PR body includes **`Closes #<n>`** so merge auto-closes the issue.

### Fix run
1. `git fetch`; **merge `origin/main` into the branch** (merge, *not* rebase —
   rebase rewrites pushed history and orphans the review-comment anchors; branch
   clutter is irrelevant because we squash-merge at the end).
   - Clean merge → continue.
   - **Conflict → do NOT invoke the agent.** Print conflicting files to the log,
     post a durable `merge-conflict — resolve & re-run` comment on the PR, and exit
     (zero credits). You then resolve **on your host** (checkout branch, merge
     `main`, fix, push) and re-fire `agent-run`. Next run's merge is clean.
2. Payload = every thread where you spoke last. Agent addresses each and **replies
   in that thread** ("done — see commit abc123"). The skill enforces the reply; the
   **script verifies** each targeted thread actually got an agent reply and flags it
   if not (don't rely on the LLM alone for a state transition).
3. Push to the same branch; done-gate re-evaluated.

### The done-gate and the unhappy path (one objective gate does both)
- **Done-gate = GUT tests green + target scene runs with no errors in the logs,
  verified by the script reading test results / exit codes** — never by asking the
  agent "did you succeed?"
- **Pass** → push + open a normal PR (`Closes #<n>`).
- **Fail / budget exceeded / stuck / merge-conflict** → push whatever exists → open
  a **Draft PR** + agent comments exactly where it stopped (failing test, ambiguous
  requirement, missing asset) + script applies a **`blocked`** label.
- Script enforces a hard **wall-clock / cost cap** (LLMs loop).
- **No auto-retry.** A failed run terminates with its Draft PR and stays there;
  re-firing is always a deliberate human command.
- **Invariant: every AFK run produces a durable GitHub signal** — a ready PR or a
  clearly-flagged blocked Draft PR. Never silence, never a silent half-push. You
  triage entirely from GitHub.

---

## Component: review-setup (host, deterministic, flag-driven)

Not an agent — a convenience command that drops you into a ready-to-review state
fast, using your **local Godot** (no sandbox). Given a work item it can:

- `git fetch` + checkout the agent branch (`agent/issue-<n>`).
- Print a **review brief**: PR diff summary + the list of unresolved threads (where
  you spoke last / still open).
- Surface **proof artifacts** (when that feature exists).
- **Launch the app** (Godot editor and/or run the scene) — behind flags.
- **Auto-seed an interactive Claude session** pre-loaded with the PR context (diff +
  unresolved threads + proof manifest) — behind a flag.

**Flag-driven:** you choose env-prep-only vs env-prep + seeded session, plus
editor/game launch flags. (Sometimes you only want to read code.)

### The review loop (the time-independence catch)
Your review is partly an interactive host conversation (game running, talking to the
agent). A later disconnected fix-run can't see that conversation — only GitHub. So
**the interactive review's *output* must be written into GitHub before the session
ends**: the host agent posts the agreed fixes as **PR review-comment threads** and
files **new issues** for future work. The talking is just how you produce that
durable state.

**Feedback medium = PR review-comment threads.** Detection rule:
> A thread **needs agent action** if the last author in it is **not the agent (bot)**.
> last author = you → needs work; last author = bot → waiting on you.
No special syntax for you to remember; fully time-independent; the fix-run's payload
is exactly "every thread where you spoke last."

---

## Entry contract — what makes an issue fire-able

The AFK agent receives essentially only the issue body (+ repo + any `CONTEXT.md`/
ADRs). Output quality is hard-bounded by issue quality. grill-me's job is to produce
issues an amnesiac agent can complete **and self-verify** autonomously. Gated by the
**`ready-for-agent`** label, which by convention means:

- **Self-contained scope** — one task sized for one autonomous run.
- **Acceptance criteria that map to the done-gate** — expressible as GUT tests +
  observable scene behavior. If the agent can't tell when it's done, it can't pass.
- **Pointers to relevant files/scenes/nodes** + explicit **out-of-scope / don't-touch**.
- **Logic-oriented** (per the concept's "good for"). Visual/feel tasks (shaders, UI
  polish, physics feel) are routed to interactive HITL, never fired at the sandbox.

(Issue quality is the human's responsibility; this plan focuses on the workflow.)

---

## Merge & close (terminal state)

- **You** squash-merge the PR (GitHub UI or a tiny deterministic `agent-merge`
  command). Merge is the most irreversible action — it stays in your hand.
- `Closes #<n>` in the PR body auto-closes the issue on merge. No special "agent
  closes the issue" act.
- **Squash-merge** keeps `main` clean despite the agent's many WIP commits (and is
  where a future `proof/`-strip would hook in).
- The interactive review agent may *recommend* shipping but never performs the merge.

---

## Deliberately deferred (workflow-first; design later)

The workflow must **not depend** on any of these — leave clean seams:

- **Proof/artifact format** — what screenshots/videos, where stored, how attached.
  Reserve a seam: a post-run hook / a `proof/` convention the agent writes to and
  review-setup surfaces. (Likely committed under `proof/issue-<n>/` on the branch,
  embedded in a PR comment, stripped from `main` at squash-merge — but undecided.)
- **The Godot↔agent inner loop** — Xvfb headless run, hi-godot MCP wiring, GUT
  harness, TDD red-green depth. ("Improve in future; focus on workflow now.")
- **The governing skills** — the detailed prompts for the fresh-implement and
  fix-comments jobs (they encode: commit semantically, write PR body with
  `Closes #<n>`, reply in-thread after fixing, run tests as the gate, report blocked
  status, write proof later).
- **Docker image build** — base image with Godot binary, MCP plugin, Claude Code,
  Xvfb, ffmpeg, `gh`, `git`.
- **Parallel-run staleness** beyond the merge-at-fix-run rule.
- **Remote/cloud execution** — clean future swap of where the container runs.

---

## Suggested build order (for the implementation session)

1. **Bot account + secrets**: create the bot GitHub account, give it push access to
   `rkibistu/godot-ai-igloo`, mint a token; decide how token + `ANTHROPIC_API_KEY`
   are injected into the container.
2. **Docker image**: Godot + Xvfb + Claude Code + `gh`/`git` + GUT; verify Godot
   runs headless and GUT can run from CLI.
3. **State-machine entrypoint script** (deterministic, no LLM yet): classify
   fresh/fix/in-review from `gh`/`git`; branch handling; fix-run `main` merge with
   conflict→exit; log `tee` to host mount; label gate prompt; push + open/update PR.
4. **Agent invocation + governing skills**: wire Claude Code headless into the
   script with the fresh/fix payloads; implement the done-gate (objective test/scene
   check) and the ready-vs-Draft-PR + `blocked` routing; in-thread reply + script
   verification; cost cap.
5. **review-setup** (host): flags for checkout / brief / app-launch / seeded session.
6. **`agent-merge`** (or just use the UI) for squash-merge.
7. **Deferred**: proof, deeper TDD, remote execution.

---

## One-line invariants to preserve

- GitHub is the only source of truth; the container is amnesiac and `--rm`.
- The script decides; the agent only writes code (+ its own commits/replies).
- Never trust the agent's self-assessment for a state transition — verify with tests/exit codes.
- Every AFK run yields a durable GitHub result — ready PR or flagged blocked Draft PR.
- No auto-retry. Merge and conflict-resolution stay human and manual.
- The agent is a distinct bot identity; "last author ≠ bot" drives the fix loop.
