#!/usr/bin/env bash
# Phase 3 binary proof: drive EVERY row of the 7-row state-machine table with hand-made
# live GitHub fixtures on rkibistu/godot-ai-igloo and assert that agent_run.sh (agent
# stubbed) routes each correctly. The fixtures are built here on the host (as the bot);
# the routing decision is made inside a fresh --rm container (as the bot). Self-cleaning:
# a leading sweep clears prior residue, a trap tears down everything this run created.
#
#   bash scripts/phase3_proof.sh
#
# Row 2 (Fix) needs a review thread whose last author != bot — which the bot cannot
# author. Set REVIEWER_GH_TOKEN in .env (the human reviewer's PAT) to cover it; without
# it row 2 is SKIPPED, not failed (the other 6 rows still prove the classifier).
set -uo pipefail
IMG=godot-ai-igloo:dev
REPO=rkibistu/godot-ai-igloo
BOT_LOGIN=justfortest1234
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

[ -f .env ] || { echo "missing .env (copy .env.example, fill BOT_GH_TOKEN)" >&2; exit 1; }
set -a; . ./.env; set +a
[ -n "${BOT_GH_TOKEN:-}" ] || { echo "BOT_GH_TOKEN unset in .env" >&2; exit 1; }

RUN_ID="p3-$(date +%s)-$$"
MARK="phase3-fixture"
TMP="$(mktemp -d)"
mkdir -p "$ROOT/runs"
declare -a FIX_ISSUES=()
declare -a RESULTS=()
PASS=1

# Fixtures are created by the active host gh session; classification doesn't depend on
# authorship, but the row-2 human thread does — warn if the host isn't the bot.
WHO="$(gh api user -q .login 2>/dev/null || true)"
[ "$WHO" = "$BOT_LOGIN" ] || echo "note: host gh is '${WHO:-none}', not bot '$BOT_LOGIN' — fixtures will be authored as '$WHO'"

cleanup() {
  echo "== teardown =="
  for n in "${FIX_ISSUES[@]+"${FIX_ISSUES[@]}"}"; do
    gh api --method DELETE "repos/$REPO/git/refs/heads/agent/issue-$n" >/dev/null 2>&1 || true
    gh issue close "$n" --repo "$REPO" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- leading sweep: close any fixture issues + delete their branches from a crashed run
echo "== sweep prior fixture residue =="
gh issue list --repo "$REPO" --search "$MARK in:title" --state all --json number --jq '.[].number' 2>/dev/null \
  | while read -r n; do
      [ -n "$n" ] || continue
      gh api --method DELETE "repos/$REPO/git/refs/heads/agent/issue-$n" >/dev/null 2>&1 || true
      gh issue close "$n" --repo "$REPO" >/dev/null 2>&1 || true
    done

# --- fixture builders --------------------------------------------------------
# gh issue/pr create use GitHub's GraphQL API, which intermittently 502s — retry the
# fixture-setup calls so a transient blip doesn't fail an otherwise-correct row.
retry() {  # run "$@", retrying on failure; echoes the command's stdout on success
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
    --body "Phase 3 proof fixture ($RUN_ID). Auto-created; auto-closed.")"
}

branch_commit() {  # $1 = issue number ; echoes head SHA (branch agent/issue-N, 1 ahead of main)
  local n="$1" br="agent/issue-$1" main_sha content
  main_sha="$(retry gh api "repos/$REPO/git/ref/heads/main" -q .object.sha)"
  retry gh api --method POST "repos/$REPO/git/refs" -f ref="refs/heads/$br" -f sha="$main_sha" >/dev/null
  content="$(printf 'phase3 fixture issue %s (%s)\n' "$n" "$RUN_ID" | base64 | tr -d '\n')"
  retry gh api --method PUT "repos/$REPO/contents/proof-fixtures/issue-$n.txt" \
    -f message="fixture: issue $n ahead of main" -f content="$content" -f branch="$br" -q .commit.sha
}

open_pr() {  # $1 = issue number, $2 = draft|ready ; echoes pr number
  local n="$1"
  if [ "$2" = draft ]; then
    basename "$(retry gh pr create --repo "$REPO" --base main --head "agent/issue-$n" --draft \
      --title "[$MARK] pr issue-$n $RUN_ID" --body "fixture PR ($RUN_ID)")"
  else
    basename "$(retry gh pr create --repo "$REPO" --base main --head "agent/issue-$n" \
      --title "[$MARK] pr issue-$n $RUN_ID" --body "fixture PR ($RUN_ID)")"
  fi
}

# --- run agent_run.sh in a fresh container (bot, agent stubbed) --------------
run_agent() {  # $1 = issue number ; combined output -> $TMP/row.log
  docker run --rm \
    -e GH_TOKEN="$BOT_GH_TOKEN" -e IS_SANDBOX=1 -e AGENT_RUN_ASSUME_READY=1 \
    -v "$ROOT/scripts:/scripts" -v "$ROOT/runs:/runs" \
    "$IMG" bash /scripts/agent_run.sh "$1" >"$TMP/row.log" 2>&1
}

check() {  # $1 label, $2 expected-class, $3 issue, $4 extra-assert(threads|draftpr|"")
  local label="$1" want="$2" n="$3" extra="${4:-}" got ok=1 notes
  case "$n" in ''|*[!0-9]*)
    echo "-> $label: SKIP run — fixture setup did not yield an issue number ('$n')"
    RESULTS+=("FAIL  $label  (fixture-setup failed: issue='$n' — transient GitHub error, re-run)"); PASS=0; return;;
  esac
  echo "-> $label (issue #$n): running classifier…"
  run_agent "$n"
  got="$(grep -m1 '^CLASS=' "$TMP/row.log" | cut -d= -f2 | tr -d '\r')"
  notes="class=${got:-<none>}"
  [ "$got" = "$want" ] || { ok=0; notes="$notes want=$want"; }
  case "$extra" in
    threads)
      grep -q '^THREADS_VERIFIED=ok' "$TMP/row.log" || { ok=0; notes="$notes THREADS_VERIFIED!=ok"; } ;;
    draftpr)
      sleep 1
      [ "$(gh pr list --repo "$REPO" --head "agent/issue-$n" --state open --json isDraft --jq '.[0].isDraft' 2>/dev/null)" = "true" ] \
        || { ok=0; notes="$notes no-Draft-PR"; } ;;
  esac
  if [ "$ok" = 1 ]; then
    RESULTS+=("PASS  $label  ($notes)")
  else
    RESULTS+=("FAIL  $label  ($notes)"); PASS=0; cp "$TMP/row.log" "$TMP/fail-$label.log"
  fi
}

echo "== build fixtures + classify (run $RUN_ID) =="

# Row 1 — Issue closed -> done
n="$(new_issue row1-done)"; FIX_ISSUES+=("$n")
gh issue close "$n" --repo "$REPO" >/dev/null
check row1-done done "$n"

# Row 6 — open issue, no branch/PR -> fresh (agent stub opens a Draft PR)
n="$(new_issue row6-fresh)"; FIX_ISSUES+=("$n")
check row6-fresh fresh "$n" draftpr

# Row 5 — branch exists, no PR -> resume-fresh (agent stub opens a Draft PR)
n="$(new_issue row5-resume)"; FIX_ISSUES+=("$n")
branch_commit "$n" >/dev/null
check row5-resume resume-fresh "$n" draftpr

# Row 4 — open Draft PR, no thread -> retry
n="$(new_issue row4-retry)"; FIX_ISSUES+=("$n")
branch_commit "$n" >/dev/null
open_pr "$n" draft >/dev/null
check row4-retry retry "$n"

# Row 3 — open Ready PR, no thread -> in-review
n="$(new_issue row3-inreview)"; FIX_ISSUES+=("$n")
branch_commit "$n" >/dev/null
open_pr "$n" ready >/dev/null
check row3-inreview in-review "$n"

# Row 7 — closed-unmerged PR -> refuse
n="$(new_issue row7-refuse)"; FIX_ISSUES+=("$n")
branch_commit "$n" >/dev/null
pr="$(open_pr "$n" draft)"
gh pr close "$pr" --repo "$REPO" >/dev/null
check row7-refuse refuse "$n"

# Row 2 — open PR with a human-authored inline thread -> fix (needs REVIEWER_GH_TOKEN)
if [ -n "${REVIEWER_GH_TOKEN:-}" ]; then
  n="$(new_issue row2-fix)"; FIX_ISSUES+=("$n")
  sha="$(branch_commit "$n")"
  pr="$(open_pr "$n" draft)"
  GH_TOKEN="$REVIEWER_GH_TOKEN" gh api --method POST "repos/$REPO/pulls/$pr/comments" \
    -f body="Please rename this fixture (Phase 3 proof human thread)." \
    -f commit_id="$sha" -f path="proof-fixtures/issue-$n.txt" -F line=1 -f side=RIGHT >/dev/null
  sleep 2
  check row2-fix fix "$n" threads
else
  RESULTS+=("SKIP  row2-fix  (REVIEWER_GH_TOKEN unset — set it in .env to author a non-bot review thread)")
fi

echo "============================================================"
printf '%s\n' "${RESULTS[@]}"
echo "============================================================"
if [ "$PASS" = 1 ]; then
  echo "PHASE 3 PROOF: PASS — every classified row routed correctly (agent stubbed)"
  exit 0
fi
echo "PHASE 3 PROOF: FAIL — see failing-row logs below (also under runs/):"
for f in "$TMP"/fail-*.log; do [ -e "$f" ] || continue; echo "----- $f -----"; cat "$f"; done
exit 1
