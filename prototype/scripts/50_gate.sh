#!/usr/bin/env bash
# Phase 5 — the objective, LLM-FREE done-gate. Run INSIDE the container.
# Zero Claude, zero MCP, zero editor, zero network: just `godot --headless`,
# grep, and exit codes decide PASS/FAIL. This is the referee the autonomous
# loop trusts instead of the agent's word.
#
# Two primitives, ANDed into one verdict:
#   Gate 1 (run-scene): the scene boots clean -> exit 0 + sentinel present + no ERROR
#   Gate 2 (GUT)      : the project's own unit tests pass -> gut exit 0
#
# Arg 1 = mode:
#   clean (default) -> run as-is; expect PASS
#   break           -> deliberately corrupt a GUT assertion to prove the gate
#                      flips RED. Safe: /project is COPY'd into the image, the
#                      container is --rm, the committed host source is untouched.
#
# Not `set -e`: we want every check + diagnostic even when one fails.
set -uo pipefail

MODE="${1:-clean}"
PROJECT=/project
SCENE=res://scenes/main.tscn
SENTINEL="PROTO_SENTINEL_READY"
TAG="$MODE"
mkdir -p /proof
echo "[*] Phase 5 — objective done-gate (no LLM)  mode=$MODE"

# 0. Optional sabotage (honesty test). Flip a true assertion to a false one so
#    GUT must report a failure. We break the TEST, not the logic, so Gate 1
#    (run-scene) stays green and only Gate 2 should turn red -> verdict flips.
if [ "$MODE" = "break" ]; then
  echo "[*] BREAK MODE: corrupting a GUT assertion to prove the gate flips red"
  sed -i 's/assert_eq(Main.add(2, 3), 5,/assert_eq(Main.add(2, 3), 999,/' \
      "$PROJECT/test/test_main.gd"
  grep -n 'Main.add(2, 3)' "$PROJECT/test/test_main.gd"
fi

# 1. Import once (a fresh container has no .godot/import; headless run needs it).
echo "[*] Importing project (headless)..."
godot --headless --path "$PROJECT" --import >/proof/import.log 2>&1 \
  || echo "[!] import nonzero (often OK)"

# ---------------------------------------------------------------------------
# Gate 1 — run the scene headless, inspect objective signals.
# `timeout` is the unambiguous safety net (main.gd self-quits via a 1s timer;
# if that ever regresses, timeout still terminates -> RC 124 -> FAIL, correct).
# `tee` discards godot's exit code, so recover it via PIPESTATUS.
# ---------------------------------------------------------------------------
echo "[*] Gate 1: running scene headless ($SCENE)..."
timeout 90 godot --headless --path "$PROJECT" "$SCENE" 2>&1 | tee "/proof/run.${TAG}.log"
RUN_RC=${PIPESTATUS[0]}
echo "[*] scene exit=$RUN_RC"

SENTINEL_OK=0; grep -q "$SENTINEL" "/proof/run.${TAG}.log" && SENTINEL_OK=1
ERRORS_OK=1;   grep -qiE "SCRIPT ERROR|\bERROR\b" "/proof/run.${TAG}.log" && ERRORS_OK=0
RUN_OK=0
if [ "$RUN_RC" -eq 0 ] && [ "$SENTINEL_OK" -eq 1 ] && [ "$ERRORS_OK" -eq 1 ]; then RUN_OK=1; fi
echo "[*] gate1: exit0=$([ "$RUN_RC" -eq 0 ] && echo 1 || echo 0) sentinel=$SENTINEL_OK no_errors=$ERRORS_OK -> RUN_OK=$RUN_OK"

# ---------------------------------------------------------------------------
# Gate 2 — run GUT from the CLI. `-gexit` quits after the run; gut_cmdln sets a
# non-zero process exit code when any test fails -> that exit code is our signal.
# The JUnit XML is a human-readable bonus artifact.
# ---------------------------------------------------------------------------
echo "[*] Gate 2: running GUT from CLI..."
timeout 120 godot --headless --path "$PROJECT" \
    -s res://addons/gut/gut_cmdln.gd \
    -gdir=res://test -gexit -gjunit_xml_file="/proof/gut.${TAG}.xml" \
    2>&1 | tee "/proof/gut.${TAG}.log"
GUT_RC=${PIPESTATUS[0]}
echo "[*] gut exit=$GUT_RC"
GUT_OK=0; [ "$GUT_RC" -eq 0 ] && GUT_OK=1
echo "[*] gate2: gut_exit=$GUT_RC -> GUT_OK=$GUT_OK"

# ---------------------------------------------------------------------------
# Verdict — AND the two gates. Verdict comes from files + exit codes only.
# ---------------------------------------------------------------------------
echo "[*] ============================================================"
if [ "$RUN_OK" -eq 1 ] && [ "$GUT_OK" -eq 1 ]; then
  echo "[*] PHASE 5 GATE: PASS  (run_ok=$RUN_OK gut_ok=$GUT_OK)"
  VERDICT=0
else
  echo "[*] PHASE 5 GATE: FAIL  (run_ok=$RUN_OK gut_ok=$GUT_OK)"
  echo "[*]          inspect /proof/run.${TAG}.log, /proof/gut.${TAG}.log, /proof/gut.${TAG}.xml"
  VERDICT=1
fi
echo "[*] ============================================================"
exit "$VERDICT"
