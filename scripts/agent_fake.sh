#!/usr/bin/env bash
# Phase-4a FAKE agent: a deterministic stand-in that exercises the REAL done-gate so the
# outcome routing in agent_run.sh can be proven for every branch — no LLM, no credits.
# Selected via AGENT_CMD, driven by FAKE_MODE (PASS | GATE_RED | TIMEOUT | BLOCK). Runs in
# /project (cwd set by agent_run.sh), commits as the bot (git identity already wired).
# Phase 4b swaps in the real timeout-wrapped Claude via the same AGENT_CMD seam.
#   agent_fake.sh <issue#> <class> <payload>
set -uo pipefail
ISSUE="${1:?issue}"
MODE="${FAKE_MODE:-PASS}"
GAME_DIR="${GAME_DIR:-/project/game}"          # the Godot project (repo's game/ subdir)
SCENE="$GAME_DIR/test/scenes/issue_${ISSUE}.tscn"
echo "AGENT_FAKE: mode=$MODE issue=$ISSUE game=$GAME_DIR"

# A minimal, valid Issue scene that boots the existing Issue0 script (draws, runs ~5s,
# quits deterministically) — satisfies gate clauses 1/2/4 without a per-issue C# file.
write_issue_scene() {
  cat > "$SCENE" <<EOF
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://test/scenes/Issue0.cs" id="1_issue0"]

[node name="Issue${ISSUE}" type="Node2D"]
script = ExtResource("1_issue0")
EOF
}

case "$MODE" in
  PASS)       # gate goes green: scene exists + boots, suite passes (Calculator intact)
    write_issue_scene
    git add -A && git commit -q -m "feat: issue #$ISSUE scene (fake PASS)" ;;
  GATE_RED)   # gate goes red: break Calculator.Multiply so CalculatorTest fails (clause 3)
    write_issue_scene
    sed -i 's/=> a \* b;/=> a + b;/' "$GAME_DIR/scripts/Calculator.cs"
    git add -A && git commit -q -m "feat: issue #$ISSUE scene + broken Multiply (fake GATE_RED)" ;;
  TIMEOUT)    # commit partial work, THEN exceed the cap (a real timed-out agent has WIP pushed)
    write_issue_scene
    git add -A && git commit -q -m "wip: issue #$ISSUE partial before timeout (fake TIMEOUT)"
    echo "AGENT_FAKE: sleeping past the cap to simulate a timeout…"
    sleep 30 ;;
  BLOCK)      # proactive substantive block: drop the marker agent_run honors + a wip commit
    echo "requirement ambiguous: issue #$ISSUE underspecified (fake BLOCK)" > "$RUNS_DIR/BLOCKED"
    git commit -q --allow-empty -m "wip: issue #$ISSUE partial — blocked (fake BLOCK)" ;;
  *)
    echo "AGENT_FAKE: unknown FAKE_MODE=$MODE" >&2; exit 2 ;;
esac
echo "AGENT_FAKE: done"
