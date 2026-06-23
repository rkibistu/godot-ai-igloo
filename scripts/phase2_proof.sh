#!/usr/bin/env bash
# Phase 2 binary proof: inside a fresh --rm container the BOT clones over HTTPS, pushes a
# branch, and opens a draft PR authored as justfortest1234 (!= rkibistu), then cleans up
# (closes the PR + deletes the branch). PASS iff PR author == bot and commit email == bot
# noreply. Re-runnable (timestamped branch + unconditional cleanup). Secrets injected via
# docker run -e from .env (never baked).
#   bash scripts/phase2_proof.sh
set -euo pipefail
IMG=godot-ai-igloo:dev
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -f .env ] || { echo "missing .env (copy .env.example, fill BOT_GH_TOKEN)" >&2; exit 1; }
set -a; . ./.env; set +a
[ -n "${BOT_GH_TOKEN:-}" ] || { echo "BOT_GH_TOKEN unset in .env" >&2; exit 1; }

RC=0
docker run --rm -i \
  -e GH_TOKEN="$BOT_GH_TOKEN" \
  -e IS_SANDBOX=1 \
  -v "$ROOT/scripts:/scripts" \
  "$IMG" bash -s <<'INCONTAINER' || RC=$?
set -uo pipefail
source /scripts/bot_init.sh || exit 2

REPO=rkibistu/godot-ai-igloo
BOT=justfortest1234
HUMAN=rkibistu
BOT_NOREPLY="142491623+justfortest1234@users.noreply.github.com"
BRANCH="phase2-proof-$(date +%Y%m%d-%H%M%S)"
PR=""

cleanup() {
  [ -n "$PR" ] && gh pr close "$PR" --repo "$REPO" --delete-branch >/dev/null 2>&1 || true
  git -C /tmp/repo push origin --delete "$BRANCH" >/dev/null 2>&1 || true   # if PR never opened
}
trap cleanup EXIT

echo "== clone (HTTPS, as bot) =="
git clone --depth 1 "https://github.com/$REPO.git" /tmp/repo
cd /tmp/repo

echo "== branch + commit + push =="
git checkout -b "$BRANCH"
# Empty commit: a proof only needs a bot-authored commit to open a PR — no scratch file,
# so nothing to collide with .gitignore (the repo ignores proof/).
git commit --allow-empty -m "chore: phase 2 bot-identity proof ($BRANCH)" >/dev/null
git push -u origin "$BRANCH"

echo "== open draft PR =="
PR_URL="$(gh pr create --repo "$REPO" --draft --base main --head "$BRANCH" \
  --title "Phase 2 proof: bot push + PR ($BRANCH)" \
  --body "Automated Phase 2 binary proof — auto-closed by scripts/phase2_proof.sh.")"
PR="$(basename "$PR_URL")"
echo "  opened PR #$PR"

echo "== assert authorship =="
AUTHOR="$(gh pr view "$PR" --repo "$REPO" --json author -q .author.login)"
CEMAIL="$(git log -1 --format=%ae)"
echo "  PR author=$AUTHOR  commit_email=$CEMAIL"

rc=0
[ "$AUTHOR" = "$BOT" ]    || { echo "  FAIL: PR author '$AUTHOR' != '$BOT'"; rc=1; }
[ "$AUTHOR" != "$HUMAN" ] || { echo "  FAIL: PR authored as human '$HUMAN'"; rc=1; }
[ "$CEMAIL" = "$BOT_NOREPLY" ] || { echo "  FAIL: commit email '$CEMAIL' != bot noreply"; rc=1; }

[ "$rc" -eq 0 ] && echo "INCONTAINER_RESULT=PASS" || echo "INCONTAINER_RESULT=FAIL"
exit "$rc"
INCONTAINER

echo "============================================================"
if [ "$RC" -eq 0 ]; then
  echo "PHASE 2 PROOF: PASS — bot pushed a branch and opened a PR as justfortest1234 (!= rkibistu)"
else
  echo "PHASE 2 PROOF: FAIL — container exit $RC (see output above)"
fi
exit "$RC"
