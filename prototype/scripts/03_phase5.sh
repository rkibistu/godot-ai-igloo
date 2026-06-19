#!/usr/bin/env bash
# Phase 5 driver (run on the HOST). Builds the image, then runs the LLM-free
# done-gate TWICE to prove the referee is HONEST:
#   RUN 1  clean  -> must PASS (rc 0)    the gate is green on good code
#   RUN 2  break  -> must FAIL (rc != 0) the gate is red on a real defect
# A gate that only ever says PASS is worthless; the flip is the whole point.
#
# No token and no network needed at runtime (pure godot --headless + GUT).
#
#   ./scripts/03_phase5.sh
set -uo pipefail
cd "$(dirname "$0")/.."   # -> prototype/

docker build -t godot-proto . || { echo "[FAIL] docker build"; exit 1; }
mkdir -p proof

echo;  echo "######## RUN 1/2: CLEAN  (expect PASS) ########"
docker run --rm -v "$PWD/proof:/proof" godot-proto /scripts/50_gate.sh clean
CLEAN_RC=$?
echo "[*] clean gate rc=$CLEAN_RC"

echo;  echo "######## RUN 2/2: BROKEN (expect FAIL) ########"
docker run --rm -v "$PWD/proof:/proof" godot-proto /scripts/50_gate.sh break
BREAK_RC=$?
echo "[*] broken gate rc=$BREAK_RC"

echo;  echo "[*] ============================================================"
# Honest gate  <=>  clean PASSES (rc 0)  AND  broken FAILS (rc != 0).
if [ "$CLEAN_RC" -eq 0 ] && [ "$BREAK_RC" -ne 0 ]; then
  echo "[*] PHASE 5: PASS — gate is GREEN on clean code and RED on a real break."
  VERDICT=0
else
  echo "[*] PHASE 5: FAIL — gate did not behave honestly (clean=$CLEAN_RC break=$BREAK_RC)"
  echo "[*]          want clean=0 and break!=0. Inspect prototype/proof/run.*.log, gut.*.log."
  VERDICT=1
fi
echo "[*] ============================================================"
echo "[*] Artifacts: prototype/proof/{run.clean.log,gut.clean.log,gut.clean.xml,run.break.log,gut.break.log,gut.break.xml}"
exit "$VERDICT"
