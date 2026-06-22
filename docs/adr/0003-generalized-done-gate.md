# Generalized done-gate: the Issue scene convention, proof-as-gate, and the weak boot-smoke

---
Status: accepted
---

The prototype's done-gate was hard-coded to one known scene + one sentinel string. For
arbitrary issues we generalize it to four objective, **script-evaluated** clauses, with
feature-verification responsibility pushed where it belongs:

1. The **Issue scene** exists at the branch-derived path `res://test/scenes/issue_<n>.tscn`
   (mandatory for every issue; absent ⇒ FAIL).
2. The Issue scene **boots/loads without runtime errors** — a *weak boot-smoke* only. It
   catches compile/parse/`_ready`/autoload/missing-resource errors; it does **not**
   exercise interactive behavior.
3. The **full test suite passes** — the sole automated *behavioral* verification and the
   cumulative behavioral-regression net.
4. A **proof video** of the Issue scene **exists** (existence only; format deferred).

**Responsibility split:** the **script** runs these mechanically (never asks the LLM "did
it work?"); the **agent + issue quality** ensure the Issue scene reaches the feature and
that behavior is under test; the **human reviewer** judges whether the feature works as
intended. The gate is a filter against wasting review time — not a proof of correctness.

## Why the Issue scene convention
A branch-derived scene path is a zero-config contract between script and agent (the script
already knows the branch `agent/issue-<n>`), gives the reviewer a ready scene to open, and
is the natural capture target for proof. The agent owns the scene's/video's *quality*; the
script checks only *existence + boot*.

## Consequences / deferred
- Re-running *all* accumulated Issue scenes as a boot/load regression net is **deferred**
  (for now only the current issue's scene is booted; the test suite carries cumulative
  behavioral regression).
- Proof artifact format, storage, PR attachment, and merge-strip remain **deferred**.
- Because the boot-smoke is weak, an issue with no behavior under test yields no automated
  feature signal — so the entry contract must demand explicit test directions.
