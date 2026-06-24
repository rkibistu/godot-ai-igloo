#!/usr/bin/env bash
# Phase 4c binary proof (CREDIT-FREE): prove the real fix loop end-to-end with a FAKE fix
# agent (scripts/agent_fix_fake.sh) — no LLM, no credits. Two checks:
#
#   A) skill-selection unit  — agent_real.sh picks fix-comments.md for a `fix` run and
#      fresh-implement.md otherwise (CLAUDE_DRYRUN=1 -> exits before any editor/claude call).
#      Always runs; needs no reviewer token.
#
#   B) fix-loop proof        — a live fixture PR with TWO human-authored inline review threads
#      on different files -> agent_run.sh classifies `fix`, builds the RICH payload (issue
#      background + both comment bodies + both diff_hunks), the fake replies in-thread on both
#      + makes a gate-safe edit, the REAL gate runs (addon provisioned by the spine), and the
#      run lands a Ready PR with both threads bot-replied. Needs REVIEWER_GH_TOKEN to author
#      the non-bot threads (the bot cannot); SKIPS cleanly without it (A still runs).
#
#   bash scripts/phase4c_proof.sh
#
# Self-cleaning: leading sweep + trap teardown. The single paid `claude -p` acceptance run is
# the user's to fire (real human thread -> real agent fixes + replies -> Ready).
set -uo pipefail
IMG=godot-ai-igloo:dev
REPO=rkibistu/godot-ai-igloo
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

[ -f .env ] || { echo "missing .env (copy .env.example, fill BOT_GH_TOKEN)" >&2; exit 1; }
set -a; . ./.env; set +a
[ -n "${BOT_GH_TOKEN:-}" ] || { echo "BOT_GH_TOKEN unset in .env" >&2; exit 1; }

RUN_ID="p4c-$(date +%s)-$$"
MARK="phase4c-fixture"
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
pass_row() { RESULTS+=("PASS  $1  ($2)"); }
fail_row() { RESULTS+=("FAIL  $1  ($2)"); PASS=0; }

# ============================================================================
# Check A — skill-selection unit (credit-free, no reviewer token, no editor)
# ============================================================================
echo "== check A: CLAUDE_DRYRUN skill selection =="
dryrun() {  # $1 = class ; echoes agent_real.sh's DRYRUN line
  docker run --rm -e CLAUDE_DRYRUN=1 -v "$ROOT/scripts:/scripts" \
    "$IMG" bash /scripts/agent_real.sh 0 "$1" /dev/null 2>&1
}
a_fix="$(dryrun fix)";   a_fresh="$(dryrun fresh)"
echo "  fix   -> $a_fix"
echo "  fresh -> $a_fresh"
if printf '%s' "$a_fix"   | grep -qF 'skill=/skills/fix-comments.md' \
&& printf '%s' "$a_fresh" | grep -qF 'skill=/skills/fresh-implement.md'; then
  pass_row dryrun-skill-select "fix->fix-comments.md, fresh->fresh-implement.md"
else
  fail_row dryrun-skill-select "got fix='$a_fix' fresh='$a_fresh'"
fi

# ============================================================================
# Check B — the fix loop (needs REVIEWER_GH_TOKEN to author non-bot threads)
# ============================================================================
if [ -z "${REVIEWER_GH_TOKEN:-}" ]; then
  RESULTS+=("SKIP  fix-loop  (REVIEWER_GH_TOKEN unset — set it in .env to author non-bot review threads)")
else
  echo "== check B: build fix fixture (run $RUN_ID) =="
  TAG="$RUN_ID"
  ISSUE_BODY="Background for the fix loop. ISSUEBODY_${TAG}. The feature already exists on the branch; do NOT re-implement."
  ACONTENT="ALPHAHUNK_${TAG}"
  BCONTENT="BETAHUNK_${TAG}"
  COMMENT_A="Rename alpha here. COMMENTA_${TAG}"
  COMMENT_B="Rename beta here. COMMENTB_${TAG}"

  n="$(basename "$(retry gh issue create --repo "$REPO" --title "[$MARK] fix-loop $RUN_ID" --body "$ISSUE_BODY")")"
  case "$n" in ''|*[!0-9]*) fail_row fix-loop "fixture issue create failed (got '$n')"; n=""; ;; esac

  if [ -n "$n" ]; then
    FIX_ISSUES+=("$n")
    br="agent/issue-$n"
    main_sha="$(retry gh api "repos/$REPO/git/ref/heads/main" -q .object.sha)"
    retry gh api --method POST "repos/$REPO/git/refs" -f ref="refs/heads/$br" -f sha="$main_sha" >/dev/null
    ca="$(printf '%s\n' "$ACONTENT" | base64 | tr -d '\n')"
    retry gh api --method PUT "repos/$REPO/contents/proof-fixtures/issue-$n-a.txt" \
      -f message="fixture A for #$n" -f content="$ca" -f branch="$br" >/dev/null
    cb="$(printf '%s\n' "$BCONTENT" | base64 | tr -d '\n')"
    head_sha="$(retry gh api --method PUT "repos/$REPO/contents/proof-fixtures/issue-$n-b.txt" \
      -f message="fixture B for #$n" -f content="$cb" -f branch="$br" -q .commit.sha)"
    # PR body carries Closes #n (as a real fresh run would have opened it) so the fix run
    # operates on a realistic PR; the spine leaves it intact and marks it Ready on pass.
    pr="$(basename "$(retry gh pr create --repo "$REPO" --base main --head "$br" --draft \
      --title "[$MARK] pr issue-$n $RUN_ID" --body "fixture PR ($RUN_ID). Closes #$n")")"
    # Two human-authored inline threads on DIFFERENT files (anchored on the PR head).
    GH_TOKEN="$REVIEWER_GH_TOKEN" gh api --method POST "repos/$REPO/pulls/$pr/comments" \
      -f body="$COMMENT_A" -f commit_id="$head_sha" -f path="proof-fixtures/issue-$n-a.txt" -F line=1 -f side=RIGHT >/dev/null
    GH_TOKEN="$REVIEWER_GH_TOKEN" gh api --method POST "repos/$REPO/pulls/$pr/comments" \
      -f body="$COMMENT_B" -f commit_id="$head_sha" -f path="proof-fixtures/issue-$n-b.txt" -F line=1 -f side=RIGHT >/dev/null
    sleep 2

    echo "== run agent_run.sh (fix-fake agent) on #$n / PR #$pr =="
    docker run --rm \
      -e GH_TOKEN="$BOT_GH_TOKEN" -e IS_SANDBOX=1 -e AGENT_RUN_ASSUME_READY=1 \
      -e AGENT_CMD=/scripts/agent_fix_fake.sh \
      -v "$ROOT/scripts:/scripts" -v "$ROOT/runs:/runs" \
      -v "$ROOT/game/addons/godot_ai:/opt/godot_ai:ro" \
      "$IMG" bash /scripts/agent_run.sh "$n" >"$TMP/fix.log" 2>&1 || true

    # --- gather facts ---
    cls="$(grep -m1 '^CLASS=' "$TMP/fix.log" | cut -d= -f2 | tr -d '\r')"
    rfile="$(ls -t "$ROOT"/runs/"$n"/*/RESULT 2>/dev/null | head -1)"
    out="$( [ -n "$rfile" ] && grep -m1 '^OUTCOME=' "$rfile" | cut -d= -f2- )"
    pfile="$(ls -t "$ROOT"/runs/"$n"/*/payload.md 2>/dev/null | head -1)"
    draft="$(gh pr view "$pr" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null)"
    body="$(gh pr view "$pr" --repo "$REPO" --json body --jq .body 2>/dev/null)"

    # --- payload richness (issue background + both comment bodies + both diff_hunks) ---
    pl_ok=1; pl_miss=""
    for needle in "ISSUEBODY_${TAG}" "COMMENTA_${TAG}" "COMMENTB_${TAG}" "ALPHAHUNK_${TAG}" "BETAHUNK_${TAG}"; do
      grep -qF "$needle" "$pfile" 2>/dev/null || { pl_ok=0; pl_miss="$pl_miss $needle"; }
    done

    # --- assert ---
    tv_ok=0; grep -q '^THREADS_VERIFIED=ok' "$TMP/fix.log" && tv_ok=1
    closes_ok=0; printf '%s' "$body" | grep -qF "Closes #$n" && closes_ok=1
    if [ "$cls" = fix ] && [ "$pl_ok" = 1 ] && [ "$tv_ok" = 1 ] \
       && [ "$out" = pass ] && [ "$draft" = false ] && [ "$closes_ok" = 1 ]; then
      pass_row fix-loop "fix, rich payload, THREADS_VERIFIED=ok, gate pass -> Ready PR #$pr (Closes #$n)"
    else
      fail_row fix-loop "class=$cls payload_ok=$pl_ok(miss:$pl_miss) threads_verified=$tv_ok outcome=$out draft=$draft closes=$closes_ok pr=#${pr:-none}"
      cp "$TMP/fix.log" "$TMP/fail-fix-loop.log" 2>/dev/null || true
    fi
  fi
fi

echo "============================================================"
printf '%s\n' "${RESULTS[@]}"
echo "============================================================"
if [ "$PASS" = 1 ]; then
  echo "PHASE 4c PROOF: PASS — fix loop builds a rich payload, replies in-thread, gates green -> Ready (credit-free)"
  exit 0
fi
echo "PHASE 4c PROOF: FAIL — failing detail below (also under runs/):"
for f in "$TMP"/fail-*.log; do [ -e "$f" ] || continue; echo "----- $f -----"; tail -60 "$f"; done
exit 1
