# Autonomous Game-Dev Agent

The ubiquitous language for an autonomous Godot dev agent (Claude Code + Godot MCP,
in an ephemeral Docker container) that implements game-logic issues end-to-end, with
GitHub as the single source of truth. This glossary is a glossary only — no
implementation details.

## Language

**Test suite**:
The full set of automated tests, run headless by the [[Done-gate]] behind a **stable
contract**: one command runs everything and returns exit 0 (pass) / non-zero (fail);
a machine-readable report is a bonus, not required. Scripting is C#, so the concrete
runner (gdUnit4 vs Chickensoft GoDotTest) is **deferred** and chosen empirically at
Phase-1 inner-loop validation — nothing else in the flow depends on which. See ADR-0002.
_Avoid_: "GUT" (GDScript-only; no longer used), "unit tests" (the suite includes
scene/integration tests).

**Done-gate**:
The objective check that decides whether a run's output is good enough to ship,
evaluated **entirely by the script** from running the app and the [[Test suite]] and
reading exit codes / logs — never by asking the LLM "did you succeed?". Its scope is
*mechanism only*: boot the [[Issue scene]] without runtime errors, run the whole
[[Test suite]], and confirm the required artifacts (the [[Issue scene]] and its
[[Proof]] video) exist. It is a filter against spending human review time on broken work,
**not** a proof of correctness.
_Avoid_: "verification", "validation" (too broad), "self-check" (the LLM never self-assesses).

**Issue scene**:
The single scene every issue must produce, at the branch-derived path
`res://test/scenes/issue_<n>.tscn`. It demonstrates the implemented feature and serves
three roles: a deterministic boot-smoke target for the [[Done-gate]], the subject of
the [[Proof]] recording, and a ready-made scene for the human reviewer to open. It is
*not* the behavioral gate — the [[Test suite]] is. Quality is the agent's/issue's
responsibility; the script only checks it exists and boots.
_Avoid_: "test scene", "demo scene" (use the canonical term).

**Proof**:
Evidence artifacts the agent produces as part of a run — at minimum a short video of
the [[Issue scene]] running. The [[Done-gate]] checks only that the video *exists*;
artifact format, storage, PR attachment, and merge-strip remain deliberately deferred.
_Avoid_: "artifact" (too generic on its own).

**Feedback thread**:
An **inline** PR review comment thread (anchored to a file+line). The *only*
fix-trigger channel: a thread needs agent action iff its last author ≠ the bot. The
host review agent can open these via `gh api .../pulls/{n}/comments`, authored as the
human (not the bot). Non-line feedback becomes a **new issue**, not a thread;
top-level PR conversation comments and review summaries are **ignored** by the
classifier.
_Avoid_: "comment" (ambiguous — conversation comments don't count), "review".

**Transient failure**:
A run that stopped for a reason that re-firing will likely clear — wall-clock cap hit,
Claude usage throttle, or a merge conflict. The work isn't wrong. The **script** (the
LLM may be dead) posts a Draft PR and a `needs-rerun` signal naming the cause; the
human just re-fires.
_Avoid_: "blocked" (reserve that for the substantive case).

**Substantive block**:
A run that can't progress without a human changing something — tests genuinely can't be
made to pass, an ambiguous requirement, a missing asset. Re-firing the same issue
unchanged won't help. The **agent** posts a Draft PR + `blocked` comment pointing at
exactly what it's stuck on.
_Avoid_: "needs-rerun" (that's the transient case).

**Test integrity**:
The separate, *soft* concern that the agent writes a genuinely failing test first and
then code to pass it without weakening the test (red→green). This lives in **issue
quality + the agent's skills/prompts**, not in the [[Done-gate]], and is deliberately
not an architectural guarantee — human PR review is the real correctness backstop.
_Avoid_: conflating with the Done-gate.
