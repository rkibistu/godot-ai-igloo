#!/usr/bin/env bash
# Phase 5 binary proof (CREDIT-FREE, HOST-side, NO container): prove review-setup drops the
# reviewer into a ready-to-review state. Builds a fixture issue + remote branch agent/issue-<n>
# (from main, so game/ exists) + a Draft PR, runs `review_setup.sh <n> --no-launch`, and asserts:
# an ISOLATED worktree is created on agent/issue-<n>, the gitignored godot_ai addon is
# provisioned into it, and the real project is checked out. Re-runs once to prove idempotency.
# Self-cleaning (leading sweep + trap teardown; zero remote residue).
#
#   bash scripts/phase5_proof.sh        # needs BOT_GH_TOKEN in .env
#
# The Godot editor WINDOW opening is a one-time MANUAL eyeball (a GUI can't be asserted
# headlessly): run `bash scripts/review_setup.sh <real-issue#>` yourself and confirm the editor
# opens with no "Failed to instantiate an autoload" error.
set -uo pipefail
REPO=rkibistu/godot-ai-igloo
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

[ -f .env ] || { echo "missing .env (copy .env.example, fill BOT_GH_TOKEN)" >&2; exit 1; }
set -a; . ./.env; set +a
[ -n "${BOT_GH_TOKEN:-}" ] || { echo "BOT_GH_TOKEN unset in .env" >&2; exit 1; }
export GH_TOKEN="$BOT_GH_TOKEN"

RUN_ID="p5-$(date +%s)-$$"
MARK="phase5-fixture"
TMP="$(mktemp -d)"
declare -a FIX_ISSUES=()
declare -a RESULTS=()
PASS=1
REVIEW_BASE="$(dirname "$ROOT")/$(basename "$ROOT")-review"   # default REVIEW_WORKTREE_DIR

teardown_issue() {  # $1 = issue number — remove the worktree, local branch, remote branch, issue
  git worktree remove --force "$REVIEW_BASE/issue-$1" >/dev/null 2>&1 || true
  rm -rf "$REVIEW_BASE/issue-$1" 2>/dev/null || true
  git branch -D "agent/issue-$1" >/dev/null 2>&1 || true
  gh api --method DELETE "repos/$REPO/git/refs/heads/agent/issue-$1" >/dev/null 2>&1 || true
  gh issue close "$1" --repo "$REPO" >/dev/null 2>&1 || true
}

cleanup() {
  echo "== teardown =="
  for n in "${FIX_ISSUES[@]+"${FIX_ISSUES[@]}"}"; do teardown_issue "$n"; done
  git worktree prune 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "== sweep prior fixture residue =="
gh issue list --repo "$REPO" --search "$MARK in:title" --state all --json number --jq '.[].number' 2>/dev/null \
  | while read -r n; do [ -n "$n" ] && teardown_issue "$n"; done
git worktree prune 2>/dev/null || true

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
pass_row() { RESULTS+=("PASS  $1  ($2)"); }
fail_row() { RESULTS+=("FAIL  $1  ($2)"); PASS=0; }

echo "== build fixture (run $RUN_ID) =="
n="$(basename "$(retry gh issue create --repo "$REPO" --title "[$MARK] review-setup $RUN_ID" \
  --body "Phase 5 proof fixture ($RUN_ID). Auto-created; auto-closed.")")"
case "$n" in ''|*[!0-9]*) echo "fixture issue create failed (got '$n')" >&2; exit 1;; esac
FIX_ISSUES+=("$n")
br="agent/issue-$n"
main_sha="$(retry gh api "repos/$REPO/git/ref/heads/main" -q .object.sha)"
retry gh api --method POST "repos/$REPO/git/refs" -f ref="refs/heads/$br" -f sha="$main_sha" >/dev/null
# A Draft PR for realism (not required by the assertions — review-setup keys off the branch).
retry gh pr create --repo "$REPO" --base main --head "$br" --draft \
  --title "[$MARK] pr issue-$n $RUN_ID" --body "fixture PR ($RUN_ID). Closes #$n" >/dev/null 2>&1 || true

WT="$REVIEW_BASE/issue-$n"
run_review() { bash "$ROOT/scripts/review_setup.sh" "$n" --no-launch >"$TMP/review.$1.log" 2>&1; echo $?; }

echo "== run review_setup (1st) =="
rc1="$(run_review 1)"
echo "== run review_setup (2nd — idempotency) =="
rc2="$(run_review 2)"

# --- assertions ---
head_ref="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
addon_ok=0; [ -d "$WT/game/addons/godot_ai" ] && addon_ok=1
proj_ok=0;  [ -f "$WT/game/project.godot" ] && proj_ok=1

if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$head_ref" = "$br" ] && [ "$addon_ok" = 1 ] && [ "$proj_ok" = 1 ]; then
  pass_row review-setup "worktree on $br, addon provisioned, project checked out, idempotent (rc=$rc1/$rc2)"
else
  fail_row review-setup "rc1=$rc1 rc2=$rc2 head=$head_ref addon=$addon_ok project=$proj_ok wt=$WT"
  cp "$TMP/review.1.log" "$TMP/fail-review.1.log" 2>/dev/null || true
  cp "$TMP/review.2.log" "$TMP/fail-review.2.log" 2>/dev/null || true
fi

echo "============================================================"
printf '%s\n' "${RESULTS[@]}"
echo "============================================================"
if [ "$PASS" = 1 ]; then
  echo "PHASE 5 PROOF: PASS — review-setup builds an isolated worktree on agent/issue-<n>, provisions the addon, idempotently (credit-free, no container)"
  exit 0
fi
echo "PHASE 5 PROOF: FAIL — detail below:"
for f in "$TMP"/fail-*.log; do [ -e "$f" ] || continue; echo "----- $f -----"; tail -40 "$f"; done
exit 1
