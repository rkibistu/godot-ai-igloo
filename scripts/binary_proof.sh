#!/usr/bin/env bash
# Phase 1 binary proof: a tiny C# change flips the 4-clause done-gate red->green,
# judged ONLY by gate exit codes (zero LLM). Each gate runs in a fresh --rm
# container against a TEMP COPY of game/ (the real tree is never mutated).
#   bash scripts/binary_proof.sh
set -uo pipefail
IMG=godot-ai-igloo:dev
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r "$ROOT/game" "$WORK/game"
mkdir -p "$WORK/proof"
CALC="$WORK/game/scripts/Calculator.cs"

gate() {  # $1 = label; runs the gate in a fresh container, returns its exit code
  docker run --rm \
    -v "$WORK/game:/project" -v "$ROOT/scripts:/scripts" -v "$WORK/proof:/proof" \
    "$IMG" bash /scripts/gate.sh 0 >"$WORK/gate_$1.log" 2>&1
}

echo "===== RED: break Calculator.Multiply (a*b -> a+b) ====="
sed -i 's/=> a \* b;/=> a + b;/' "$CALC"
gate red; RED_RC=$?
echo "RED gate exit = $RED_RC"; grep -E "GATE #0|Failed!" "$WORK/gate_red.log" | tail -2

echo "===== GREEN: restore correct Multiply ====="
cp "$ROOT/game/scripts/Calculator.cs" "$CALC"
gate green; GREEN_RC=$?
echo "GREEN gate exit = $GREEN_RC"; grep -E "GATE #0|Passed!" "$WORK/gate_green.log" | tail -2

echo "============================================================"
if [ "$RED_RC" -ne 0 ] && [ "$GREEN_RC" -eq 0 ]; then
  echo "BINARY PROOF: PASS — gate flipped red(rc=$RED_RC) -> green(rc=$GREEN_RC), LLM-free"
  exit 0
fi
echo "BINARY PROOF: FAIL — red_rc=$RED_RC (want !=0), green_rc=$GREEN_RC (want 0)"
exit 1
