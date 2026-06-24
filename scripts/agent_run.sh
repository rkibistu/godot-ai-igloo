#!/usr/bin/env bash
# The deterministic state-machine entrypoint (Phase 3). Runs INSIDE a fresh --rm
# container. Reconstructs task state from gh+git, classifies it against the 7-row table
# (plan_implementation.md), prepares the branch, gathers a payload, invokes the agent
# (a STUB in Phase 3 — see AGENT_CMD), then pushes + opens/updates a Draft PR. ZERO LLM
# in any state transition: the script decides, the agent only writes code.
#
#   source /scripts/bot_init.sh    # (done internally; safe to also do before)
#   bash /scripts/agent_run.sh <issue-number>
#
# Scope: classify + plumb (Phase 3) + post-exit done-gate & outcome routing (Phase 4a).
# The agent is invoked via AGENT_CMD (stub/fake until 4b wires real Claude). After it
# returns, the SCRIPT decides the outcome and routes to a durable GitHub signal:
#   pass -> Ready PR (Closes #n) · timeout -> Draft+needs-rerun · block/gate-fail -> Draft+blocked.
#
# Exit codes: 0 ok/early-exit · 64 usage/missing-issue · 65 refuse (closed-unmerged PR)
#   · 66 stopped at soft label gate · 70 internal · 75 transient (merge conflict).
set -uo pipefail

ISSUE="${1:-}"
case "$ISSUE" in ''|*[!0-9]*) echo "agent_run: usage: agent_run.sh <issue-number>" >&2; exit 64;; esac

REPO="rkibistu/godot-ai-igloo"
OWNER="${REPO%/*}"; NAME="${REPO#*/}"
REPO_URL="https://github.com/${REPO}.git"
BRANCH="agent/issue-${ISSUE}"
PROJ=/project
RUNS_DIR="/runs/${ISSUE}/$(date -u +%Y%m%dT%H%M%SZ)"
AGENT_CMD="${AGENT_CMD:-/scripts/agent_stub.sh}"

# --- logging: tee everything (stdout+stderr) to the host-mounted, per-run log ---
mkdir -p "$RUNS_DIR"
exec > >(tee -a "$RUNS_DIR/run.log") 2>&1
echo "== agent-run #$ISSUE @ $(date -u +%FT%TZ) =="

# --- identity + HTTPS auth (single source of the bot login/email) ---
# shellcheck disable=SC1091
source /scripts/bot_init.sh || { echo "agent_run: bot_init failed (GH_TOKEN unset?)"; exit 70; }
# bot_init exports nothing but, sourced, leaves $BOT_LOGIN / $BOT_EMAIL in scope.

# --- helpers -----------------------------------------------------------------

# Prints one TAB line per ACTIONABLE review thread on the given open PR:
#   <reply_target_comment_id>\t<path>\t<line>\t<last_author>
# Actionable = NOT resolved AND last comment's author != the bot (the canonical rule).
# Top-level conversation comments / review summaries are not reviewThreads -> ignored.
actionable_threads() {  # $1 = pr number
  gh api graphql \
    -F owner="$OWNER" -F name="$NAME" -F pr="$1" \
    -f query='
      query($owner:String!,$name:String!,$pr:Int!){
        repository(owner:$owner,name:$name){
          pullRequest(number:$pr){
            reviewThreads(first:100){ nodes{
              isResolved
              comments(first:100){ nodes{ databaseId author{login} path line } }
            }}
          }
        }
      }' \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[]
          | select(.isResolved==false)
          | {first:.comments.nodes[0], last:(.comments.nodes|last)}
          | select(.last.author.login != "'"$BOT_LOGIN"'")
          | "\(.first.databaseId)\t\(.first.path)\t\(.first.line)\t\(.last.author.login)"' \
    2>/dev/null
}

apply_label() {  # $1 = pr/issue number, $2 = label  (best-effort; never fatal)
  gh label create "$2" --repo "$REPO" --color ededed --force >/dev/null 2>&1 || true
  gh pr edit "$1" --repo "$REPO" --add-label "$2" >/dev/null 2>&1 || true
}
remove_label() {  # $1 = pr number, $2 = label  (best-effort)
  gh pr edit "$1" --repo "$REPO" --remove-label "$2" >/dev/null 2>&1 || true
}
# Post the run's durable signal: a PR comment if a PR exists, else an issue comment.
signal() {  # $1 = body
  if [ -n "${PR_NUM:-}" ]; then
    gh pr comment "$PR_NUM" --repo "$REPO" --body "$1" >/dev/null 2>&1 || true
  else
    gh issue comment "$ISSUE" --repo "$REPO" --body "$1" >/dev/null 2>&1 || true
  fi
}

# Pure routing decision — the heart of the state machine (no GitHub calls).
# Mirrors the table in plan_implementation.md, ordered so a closed-unmerged PR is
# checked before the "no PR" rows.
classify_from_facts() {  # $1 issue_state $2 pr_state $3 pr_draft $4 has_thread $5 branch_exists
  local issue="$1" pr="$2" draft="$3" thread="$4" branch="$5"
  if [ "$issue" = "CLOSED" ] || [ "$pr" = "MERGED" ]; then echo done; return; fi
  if [ "$pr" = "OPEN" ]; then
    if [ "$thread" = "true" ]; then echo fix
    elif [ "$draft" = "true" ]; then echo retry
    else echo in-review; fi
    return
  fi
  if [ "$pr" = "CLOSED" ]; then echo refuse; return; fi
  if [ "$branch" = "true" ]; then echo resume-fresh; else echo fresh; fi
}

# --- probes (no clone — git ls-remote + gh query the remote directly) --------
echo "== probe =="
ISTATE="$(gh issue view "$ISSUE" --repo "$REPO" --json state --jq .state 2>/dev/null || echo MISSING)"
[ "$ISTATE" = "MISSING" ] && { echo "agent_run: issue #$ISSUE not found in $REPO." >&2; exit 64; }

# Most-recent PR (by number) whose head is our branch, across all states.
PRLINE="$(gh pr list --repo "$REPO" --head "$BRANCH" --state all \
  --json number,state,isDraft \
  --jq 'sort_by(.number) | last | "\(.state)|\(.isDraft)|\(.number)"' 2>/dev/null || true)"
PR_STATE=NONE; PR_DRAFT=false; PR_NUM=""
if [ -n "$PRLINE" ] && [ "$PRLINE" != "null|null|null" ]; then
  PR_STATE="${PRLINE%%|*}"; _rest="${PRLINE#*|}"; PR_DRAFT="${_rest%%|*}"; PR_NUM="${_rest##*|}"
fi

BRANCH_EXISTS=false
git ls-remote --heads "$REPO_URL" "$BRANCH" 2>/dev/null | grep -q . && BRANCH_EXISTS=true

HAS_THREAD=false; ACTION_THREADS=""
if [ "$PR_STATE" = "OPEN" ] && [ -n "$PR_NUM" ]; then
  ACTION_THREADS="$(actionable_threads "$PR_NUM")"
  [ -n "$ACTION_THREADS" ] && HAS_THREAD=true
fi

CLASS="$(classify_from_facts "$ISTATE" "$PR_STATE" "$PR_DRAFT" "$HAS_THREAD" "$BRANCH_EXISTS")"
echo "FACTS: issue=$ISTATE pr=$PR_STATE draft=$PR_DRAFT thread=$HAS_THREAD branch=$BRANCH_EXISTS pr_num=${PR_NUM:-none}"
echo "CLASS=$CLASS"

# --- early-exit classes (zero further work, no clone, no tokens) -------------
case "$CLASS" in
  done)      echo "agent_run: issue #$ISSUE already done (closed, or PR merged) — nothing to do."; exit 0;;
  in-review) echo "agent_run: PR #$PR_NUM is Ready with no actionable threads — awaiting human. Nothing to do."; exit 0;;
  refuse)    echo "agent_run: PR #$PR_NUM is closed without merging. Reopen it, or delete branch $BRANCH to start fresh."; exit 65;;
esac

# --- soft label gate (proceeding classes only) ------------------------------
HAS_READY="$(gh issue view "$ISSUE" --repo "$REPO" --json labels \
  --jq 'any(.labels[]; .name=="ready-for-agent")' 2>/dev/null || echo false)"
if [ "$HAS_READY" != "true" ]; then
  if [ "${AGENT_RUN_ASSUME_READY:-}" = "1" ]; then
    echo "agent_run: 'ready-for-agent' absent — proceeding (AGENT_RUN_ASSUME_READY=1)."
  elif [ -t 0 ]; then
    read -r -p "agent_run: issue #$ISSUE lacks 'ready-for-agent'. Continue anyway? [y/N] " ans
    case "$ans" in y|Y|yes|YES) ;; *) echo "agent_run: stopped at soft label gate."; exit 66;; esac
  else
    echo "agent_run: 'ready-for-agent' absent and no TTY; set AGENT_RUN_ASSUME_READY=1 to override." >&2
    exit 66
  fi
fi

# --- clone fresh + prepare branch -------------------------------------------
echo "== clone fresh (amnesiac) =="
cd /                       # never rm/clone from inside $PROJ (it is the WORKDIR)
rm -rf "$PROJ"
git clone --quiet "$REPO_URL" "$PROJ"
cd "$PROJ"

echo "== prepare branch ($CLASS) =="
case "$CLASS" in
  fresh)
    git checkout -q -b "$BRANCH" origin/main ;;
  resume-fresh|retry)
    git checkout -q -b "$BRANCH" "origin/$BRANCH" ;;
  fix)
    git checkout -q -b "$BRANCH" "origin/$BRANCH"
    echo "== fix-run: merge origin/main (preserves thread anchors) =="
    if ! git merge --no-edit origin/main; then
      CONFLICTS="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
      git merge --abort 2>/dev/null || true
      echo "agent_run: MERGE CONFLICT in: $CONFLICTS"
      gh pr comment "$PR_NUM" --repo "$REPO" \
        --body "⚠️ merge-conflict with \`main\` in: $CONFLICTS — resolve locally & re-run. (no agent invoked, zero credits)" || true
      apply_label "$PR_NUM" needs-rerun
      exit 75
    fi ;;
esac

# --- gather payload ----------------------------------------------------------
echo "== gather payload =="
PAYLOAD="$RUNS_DIR/payload.md"
if [ "$CLASS" = "fix" ]; then
  printf '%s\n' "$ACTION_THREADS" > "$RUNS_DIR/threads.tsv"
  {
    echo "# Fix payload — issue #$ISSUE, PR #$PR_NUM"
    echo "Address each unresolved review thread, then reply in-thread on each."
    echo
    printf '%s\n' "$ACTION_THREADS" | while IFS=$'\t' read -r cid path line author; do
      [ -n "$cid" ] || continue
      echo "- comment_id=$cid  $path:$line  (last author: $author)"
    done
  } > "$PAYLOAD"
else
  {
    echo "# Implement payload — issue #$ISSUE"
    echo
    gh issue view "$ISSUE" --repo "$REPO" --json title,body --jq '"## "+.title+"\n\n"+(.body // "")'
  } > "$PAYLOAD"
fi

# --- invoke the agent under a wall-clock cap (AGENT_CMD is the seam) ----------
# AGENT_CMD is a script PATH, run via bash (bind-mounted scripts are 0644, not +x).
AGENT_TIMEOUT="${AGENT_TIMEOUT:-2700}"     # ~45 min cap (env-tunable); 4b wires real Claude
# The Godot project is the repo's game/ subdir; /project is the cloned repo (git) root.
GAME_DIR="$PROJ/game"; PROJECT_DIR="$GAME_DIR"
PROOF_DIR="$RUNS_DIR/proof"; mkdir -p "$PROOF_DIR"
echo "== invoke agent: $AGENT_CMD (timeout ${AGENT_TIMEOUT}s) =="
export REPO OWNER NAME BRANCH PR_NUM BOT_LOGIN RUNS_DIR CLASS ISSUE PROOF_DIR GAME_DIR PROJECT_DIR
TIMED_OUT=0
timeout "$AGENT_TIMEOUT" bash "$AGENT_CMD" "$ISSUE" "$CLASS" "$PAYLOAD"
AGENT_RC=$?
case "$AGENT_RC" in 124|137) TIMED_OUT=1;; esac
echo "agent exit=$AGENT_RC timed_out=$TIMED_OUT"

# --- decide the outcome (top-down; the SCRIPT decides, never the LLM) ---------
OUTCOME=""; OUTCOME_MSG=""
if [ "$TIMED_OUT" = 1 ]; then
  OUTCOME=transient; OUTCOME_MSG="agent hit the ${AGENT_TIMEOUT}s wall-clock cap (timeout)"
elif [ -f "$RUNS_DIR/BLOCKED" ]; then
  OUTCOME=substantive; OUTCOME_MSG="agent reported a block — $(head -1 "$RUNS_DIR/BLOCKED")"
else
  echo "== done-gate (post-exit) =="
  if bash /scripts/gate.sh "$ISSUE" >"$RUNS_DIR/gate.log" 2>&1; then
    OUTCOME=pass; OUTCOME_MSG="done-gate passed (4/4 clauses)"
  else
    OUTCOME=substantive
    CLAUSE="$(grep -m1 "GATE #$ISSUE: FAIL" "$RUNS_DIR/gate.log" | sed 's/.*FAIL — //')"
    OUTCOME_MSG="done-gate failed — ${CLAUSE:-see gate.log}"
  fi
  tail -n 20 "$RUNS_DIR/gate.log"
fi
echo "OUTCOME=$OUTCOME"
echo "OUTCOME_MSG=$OUTCOME_MSG"

# --- push (always — capture whatever work exists) ----------------------------
echo "== push =="
git push -u origin "$BRANCH" 2>&1 || echo "agent_run: push returned nonzero (continuing)"
AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"

# --- ensure a PR exists (Draft by default; a PR needs a diff) ----------------
if [ "$PR_STATE" = "OPEN" ] && [ -n "$PR_NUM" ]; then
  echo "agent_run: PR #$PR_NUM already open — updated by push."
elif [ "${AHEAD:-0}" -gt 0 ]; then
  echo "== open Draft PR =="
  PR_URL="$(gh pr create --repo "$REPO" --draft --base main --head "$BRANCH" \
    --title "[agent] issue #$ISSUE" \
    --body "Automated PR for #$ISSUE. Closes #$ISSUE")"
  PR_NUM="$(basename "$PR_URL")"
  echo "opened Draft PR #$PR_NUM"
else
  echo "agent_run: no commits ahead of main — posting the signal as an issue comment (no PR)."
fi

# --- route the outcome (script owns push + PR state + label + comment) -------
echo "== route outcome: $OUTCOME =="
ROUTED=""
case "$OUTCOME" in
  pass)
    if [ -n "${PR_NUM:-}" ]; then
      gh pr ready "$PR_NUM" --repo "$REPO" >/dev/null 2>&1 || true
      remove_label "$PR_NUM" needs-rerun; remove_label "$PR_NUM" blocked
      signal "✅ done-gate passed — marking this PR **Ready** for review. Closes #$ISSUE."
      ROUTED="ready"
    else
      signal "✅ done-gate passed, but there is no diff to open a PR."
      ROUTED="pass-no-pr"
    fi ;;
  transient)
    [ -n "${PR_NUM:-}" ] && apply_label "$PR_NUM" needs-rerun
    signal "⏱️ **transient stop** — $OUTCOME_MSG. Work pushed; just re-run (nothing to fix)."
    ROUTED="draft+needs-rerun" ;;
  substantive)
    [ -n "${PR_NUM:-}" ] && apply_label "$PR_NUM" blocked
    signal "🚫 **blocked** — $OUTCOME_MSG"
    ROUTED="draft+blocked" ;;
esac
echo "ROUTED=$ROUTED pr=#${PR_NUM:-none}"

# Machine-readable result, written with a DIRECT (non-tee) redirect so the proof's
# assertions never depend on stdout-pipe flushing at container exit.
printf 'OUTCOME=%s\nROUTED=%s\nPR=%s\nOUTCOME_MSG=%s\n' \
  "$OUTCOME" "$ROUTED" "${PR_NUM:-}" "$OUTCOME_MSG" > "$RUNS_DIR/RESULT"

# --- post-run verification: every targeted thread got a bot reply (fix only) -
if [ "$CLASS" = "fix" ]; then
  echo "== verify thread replies =="
  REMAIN="$(actionable_threads "$PR_NUM")"
  if [ -z "$REMAIN" ]; then
    echo "THREADS_VERIFIED=ok"
  else
    echo "THREADS_VERIFIED=FAIL — threads still missing a bot reply:"
    printf '%s\n' "$REMAIN"
  fi
fi

echo "agent_run: done (class=$CLASS, outcome=$OUTCOME, pr=#${PR_NUM:-none})"
