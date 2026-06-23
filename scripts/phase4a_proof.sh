#!/usr/bin/env bash
# Phase 4a binary proof: prove the outcome routing in agent_run.sh. A FAKE agent
# (scripts/agent_fake.sh) deterministically drives each outcome the router must handle —
# pass / timeout / gate-red / agent-block — and we assert the run lands the correct durable
# GitHub signal: a Ready PR (pass) or a flagged Draft PR (transient/substantive). The real
# done-gate runs for real (no LLM, no credits). Live fixtures on rkibistu/godot-ai-igloo;
# self-cleaning (trap teardown + leading sweep).
#
#   bash scripts/phase4a_proof.sh
set -uo pipefail
IMG=godot-ai-igloo:dev
REPO=rkibistu/godot-ai-igloo
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

[ -f .env ] || { echo "missing .env (copy .env.example, fill BOT_GH_TOKEN)" >&2; exit 1; }
set -a; . ./.env; set +a
[ -n "${BOT_GH_TOKEN:-}" ] || { echo "BOT_GH_TOKEN unset in .env" >&2; exit 1; }

RUN_ID="p4a-$(date +%s)-$$"
MARK="phase4a-fixture"
TMP="$(mktemp -d)"
mkdir -p "$ROOT/runs"
declare -a FIX_ISSUES=()
declare -a RESULTS=()
PASS=1

cleanup() {
  echo "== teardown =="
  for n in "${FIX_ISSUES[@]+"${FIX_ISSUES[@]}"}"; do
    gh api --method DELETE "repos/$REPO/git/refs/heads/agent/issue-$n" >/dev/null 2>&1 || true
    gh issue close "$n" --repo "$REPO" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "== sweep prior fixture residue =="
gh issue list --repo "$REPO" --search "$MARK in:title" --state all --json number --jq '.[].number' 2>/dev/null \
  | while read -r n; do
      [ -n "$n" ] || continue
      gh api --method DELETE "repos/$REPO/git/refs/heads/agent/issue-$n" >/dev/null 2>&1 || true
      gh issue close "$n" --repo "$REPO" >/dev/null 2>&1 || true
    done

# gh issue/pr create ride GraphQL, which intermittently 502s — retry fixture-setup calls.
retry() {
  local i out rc=0 err="$TMP/retry.err"
  for i in 1 2 3 4 5; do
    if out="$("$@" 2>"$err")"; then printf '%s' "$out"; return 0; fi
    rc=$?; sleep $(( i * 2 ))
  done
  echo "retry: gave up after 5 attempts: $*" >&2; cat "$err" >&2 2>/dev/null
  return "$rc"
}
new_issue() {  # $1 = label ; echoes issue number
  basename "$(retry gh issue create --repo "$REPO" --title "[$MARK] $1 $RUN_ID" \
    --body "Phase 4a proof fixture ($RUN_ID). Auto-created; auto-closed.")"
}

# Run the full entrypoint in a fresh --rm container with the fake agent.
run_agent() {  # $1 issue, $2 FAKE_MODE, $3 AGENT_TIMEOUT
  docker run --rm \
    -e GH_TOKEN="$BOT_GH_TOKEN" -e IS_SANDBOX=1 -e AGENT_RUN_ASSUME_READY=1 \
    -e AGENT_CMD=/scripts/agent_fake.sh -e FAKE_MODE="$2" -e AGENT_TIMEOUT="$3" \
    -v "$ROOT/scripts:/scripts" -v "$ROOT/runs:/runs" \
    "$IMG" bash /scripts/agent_run.sh "$1" >"$TMP/row.log" 2>&1
}

# Read the tee-independent RESULT file agent_run writes to the mounted run dir (one run
# per fixture issue) — robust against stdout-pipe truncation at container exit.
logval()      { local f; f="$(ls -t "$ROOT"/runs/"$2"/*/RESULT 2>/dev/null | head -1)"; [ -n "$f" ] && grep -m1 "^$1=" "$f" | cut -d= -f2-; }
pr_for()      { gh pr list --repo "$REPO" --head "agent/issue-$1" --state open --json number --jq '.[0].number' 2>/dev/null; }
pr_field()    { gh pr view "$1" --repo "$REPO" --json "$2" --jq ".$2" 2>/dev/null; }
has_label()   { gh pr view "$1" --repo "$REPO" --json labels   --jq '.labels[].name'   2>/dev/null | grep -qx "$2"; }
has_comment() { gh pr view "$1" --repo "$REPO" --json comments --jq '.comments[].body' 2>/dev/null | grep -qiE "$2"; }

pass_row() { RESULTS+=("PASS  $1  ($2)"); }
fail_row() { RESULTS+=("FAIL  $1  ($2)"); PASS=0; cp "$TMP/row.log" "$TMP/fail-$1.log" 2>/dev/null || true; }

echo "== build fixtures + drive outcomes (run $RUN_ID) =="

# --- PASS: gate green -> Ready PR with Closes #n ---------------------------
n="$(new_issue pass)"; FIX_ISSUES+=("$n")
echo "-> pass (issue #$n): fake agent + real done-gate (this one builds + renders)…"
run_agent "$n" PASS 5
pr="$(pr_for "$n")"; out="$(logval OUTCOME "$n")"; draft="$(pr_field "$pr" isDraft)"; body="$(pr_field "$pr" body)"
if [ "$out" = pass ] && [ "$draft" = false ] && printf '%s' "$body" | grep -q "Closes #$n"; then
  pass_row pass "Ready PR #$pr, Closes #$n, gate green"
else
  fail_row pass "outcome=$out draft=$draft pr=#${pr:-none} (want pass/false/Closes#$n)"
fi

# --- TIMEOUT: wall-clock cap -> Draft + needs-rerun ------------------------
n="$(new_issue timeout)"; FIX_ISSUES+=("$n")
echo "-> timeout (issue #$n): fake agent sleeps past a 3s cap…"
run_agent "$n" TIMEOUT 3
pr="$(pr_for "$n")"; out="$(logval OUTCOME "$n")"; draft="$(pr_field "$pr" isDraft)"
if [ "$out" = transient ] && [ "$draft" = true ] && has_label "$pr" needs-rerun && has_comment "$pr" "transient stop"; then
  pass_row timeout "Draft PR #$pr + needs-rerun + comment"
else
  fail_row timeout "outcome=$out draft=$draft pr=#${pr:-none} (want transient/true/needs-rerun)"
fi

# --- GATE_RED: gate red -> Draft + blocked --------------------------------
n="$(new_issue gatered)"; FIX_ISSUES+=("$n")
echo "-> gate-red (issue #$n): fake agent breaks Multiply (real gate goes red)…"
run_agent "$n" GATE_RED 5
pr="$(pr_for "$n")"; out="$(logval OUTCOME "$n")"; draft="$(pr_field "$pr" isDraft)"
if [ "$out" = substantive ] && [ "$draft" = true ] && has_label "$pr" blocked && has_comment "$pr" "done-gate failed"; then
  pass_row gate-red "Draft PR #$pr + blocked + failing-clause comment"
else
  fail_row gate-red "outcome=$out draft=$draft pr=#${pr:-none} (want substantive/true/blocked)"
fi

# --- BLOCK: agent marker -> Draft + blocked (agent's reason) ---------------
n="$(new_issue block)"; FIX_ISSUES+=("$n")
echo "-> block (issue #$n): fake agent drops a BLOCKED marker…"
run_agent "$n" BLOCK 5
pr="$(pr_for "$n")"; out="$(logval OUTCOME "$n")"; draft="$(pr_field "$pr" isDraft)"
if [ "$out" = substantive ] && [ "$draft" = true ] && has_label "$pr" blocked && has_comment "$pr" "blocked"; then
  pass_row block "Draft PR #$pr + blocked + agent reason"
else
  fail_row block "outcome=$out draft=$draft pr=#${pr:-none} (want substantive/true/blocked)"
fi

echo "============================================================"
printf '%s\n' "${RESULTS[@]}"
echo "============================================================"
if [ "$PASS" = 1 ]; then
  echo "PHASE 4a PROOF: PASS — gate + outcome routing land the right signal for every case"
  exit 0
fi
echo "PHASE 4a PROOF: FAIL — failing-row logs below (also under runs/):"
for f in "$TMP"/fail-*.log; do [ -e "$f" ] || continue; echo "----- $f -----"; cat "$f"; done
exit 1
