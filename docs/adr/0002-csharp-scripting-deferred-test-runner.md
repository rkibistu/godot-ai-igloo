# C# scripting; concrete test runner deferred behind the done-gate contract

---
Status: accepted
---

We adopt **C#** as the scripting language for the agent's game-logic work, reversing
the feasibility prototype's deliberate GDScript choice. C# buys static typing, the
.NET tooling/ecosystem, a compile step that turns a whole class of errors into clean
early [[Done-gate]] failures, and a strong Godot-C# ecosystem (Chickensoft — LogicBlocks
for state machines, GodotTestDriver for input-driven scenes, a headless-render CI
template) that lines up with this project's focus on logic/state-machine work.

Because GUT — the prototype's proven gate runner — is **GDScript-only**, the concrete
C# test runner (**gdUnit4** vs **Chickensoft GoDotTest**) is **deliberately deferred**.
The whole flow is designed against a stable done-gate contract instead: *one command
runs the full suite headless and returns exit 0 (pass) / non-zero (fail); a
machine-readable report is a bonus, not a requirement.* Nothing in the workflow depends
on which runner sits behind that contract, so the pick is made empirically at Phase-1
inner-loop validation, when both can be tried against the real image.

## Consequences

- The image needs the **.NET/Mono Godot build + .NET SDK** (not the GDScript build the
  prototype pinned), and a **compile step** precedes every gate run.
- The prototype's GDScript/GUT green checks **do not transfer**; Phase 1 must
  re-validate the C# inner loop end-to-end (build, runner, MCP `.cs` handling).
- Whether the `godot_ai` MCP supports `.cs` script create/attach is **unverified** —
  covered by the rule: prefer MCP, else hand-edit the file and flag it in a PR comment.

## Resolution (2026-06-22)

Runner chosen: **gdUnit4** — C#-capable, embedded, with a CLI runner + JUnit XML + exit
code, i.e. the closest carry-over of the proven GUT gate mechanics (and it keeps GDScript
on the table). It stays behind the `run-tests` contract, so a later swap remains cheap.
