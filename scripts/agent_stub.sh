#!/usr/bin/env bash
# Phase-3 STAND-IN for the real agent. agent_run.sh invokes it via the AGENT_CMD seam;
# Phase 4 replaces it with the real `timeout`-wrapped Claude Code call (no change to
# agent_run.sh). It does the minimum the deterministic spine needs to exercise its
# push / PR / thread-verification plumbing — NO Godot, NO done-gate, NO LLM:
#   - makes one (empty) semantic commit so the branch advances and a PR can open/update;
#   - on a `fix` run, posts an in-thread reply to each targeted review thread, so the
#     spine's post-run "every thread got a bot reply" check has something real to confirm.
#
#   agent_stub.sh <issue#> <class> <payload-file>
# Inherits from agent_run.sh (exported): REPO, PR_NUM, BRANCH, BOT_LOGIN, RUNS_DIR, CLASS.
set -uo pipefail

ISSUE="${1:?issue}"; CLASS="${2:?class}"; PAYLOAD="${3:-}"
: "${REPO:?REPO not exported}"

echo "AGENT_STUB: start (issue=$ISSUE class=$CLASS payload=$PAYLOAD)"

# One semantic, deterministic commit standing in for the agent's real work.
git commit --allow-empty -q -m "stub: $CLASS work for #$ISSUE (Phase 3 agent stub)"

# Fix runs: reply in-thread on every targeted thread (the rule the real skill enforces).
if [ "$CLASS" = "fix" ]; then
  THREADS="$RUNS_DIR/threads.tsv"
  if [ -s "$THREADS" ]; then
    while IFS=$'\t' read -r cid path line author; do
      [ -n "$cid" ] || continue
      echo "AGENT_STUB: replying in thread comment_id=$cid ($path:$line)"
      gh api --method POST "repos/$REPO/pulls/$PR_NUM/comments/$cid/replies" \
        -f body="Addressed in the latest commit (Phase 3 stub reply)." >/dev/null \
        || echo "AGENT_STUB: WARN reply to $cid failed"
    done < "$THREADS"
  else
    echo "AGENT_STUB: no threads.tsv to reply to"
  fi
fi

echo "AGENT_STUB: done"
