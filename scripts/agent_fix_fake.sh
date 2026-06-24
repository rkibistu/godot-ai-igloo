#!/usr/bin/env bash
# Phase-4c credit-free FIX agent: the AGENT_CMD used by phase4c_proof.sh to exercise the
# REAL done-gate + the spine's per-thread reply verification for a `fix` run — no LLM, no
# credits. Phase 4c's real brain is `claude -p` + skills/fix-comments.md (via agent_real.sh);
# this fake stands in so the deterministic fix plumbing is provable for free. It leaves
# behind exactly what a SUCCESSFUL fix run must:
#   - an in-thread reply on EVERY targeted review thread (threads.tsv anchors) — the rule
#     skills/fix-comments.md enforces and agent_run.sh:283 verifies;
#   - a gate-green tree: writes the Issue scene (clauses 1/2/4) and leaves Calculator intact
#     (clause 3) -> gate PASS -> the spine marks the PR Ready;
#   - a semantic commit as the bot.
# (Stuck->Draft+blocked is NOT re-proven here — Phase 4a's BLOCK path already covers it.)
#
#   agent_fix_fake.sh <issue#> <class> <payload-file>
# Inherits from agent_run.sh (exported): REPO, PR_NUM, RUNS_DIR, GAME_DIR.
set -uo pipefail
ISSUE="${1:?issue}"; CLASS="${2:-fix}"; PAYLOAD="${3:-}"
: "${REPO:?REPO not exported}"; : "${PR_NUM:?PR_NUM not exported}"
GAME_DIR="${GAME_DIR:-/project/game}"
RUNS_DIR="${RUNS_DIR:-/tmp/run}"
SCENE="$GAME_DIR/test/scenes/issue_${ISSUE}.tscn"
echo "AGENT_FIX_FAKE: start (issue=$ISSUE class=$CLASS pr=$PR_NUM)"

# Gate-safe Issue scene: boots the existing Issue0 script (draws, runs ~5s, deterministic
# quit) -> satisfies gate clauses 1/2/4 without a per-issue C# file. (Same as agent_fake.sh.)
write_issue_scene() {
  mkdir -p "$(dirname "$SCENE")"
  cat > "$SCENE" <<EOF
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://test/scenes/Issue0.cs" id="1_issue0"]

[node name="Issue${ISSUE}" type="Node2D"]
script = ExtResource("1_issue0")
EOF
}

# Reply in-thread on every targeted thread. threads.tsv was written by agent_run.sh from the
# proven actionable_threads anchors; the reply call mirrors agent_stub.sh.
THREADS="$RUNS_DIR/threads.tsv"
if [ -s "$THREADS" ]; then
  while IFS=$'\t' read -r cid path line author; do
    [ -n "$cid" ] || continue
    echo "AGENT_FIX_FAKE: replying in thread comment_id=$cid ($path:$line)"
    gh api --method POST "repos/$REPO/pulls/$PR_NUM/comments/$cid/replies" \
      -f body="Addressed in the latest commit (Phase 4c fix-fake reply)." >/dev/null \
      || echo "AGENT_FIX_FAKE: WARN reply to $cid failed"
  done < "$THREADS"
else
  echo "AGENT_FIX_FAKE: no threads.tsv to reply to"
fi

write_issue_scene
git add -A
git commit -q -m "fix: address review on #$ISSUE (Phase 4c fix-fake)" \
  || echo "AGENT_FIX_FAKE: nothing new to commit"
echo "AGENT_FIX_FAKE: done"
