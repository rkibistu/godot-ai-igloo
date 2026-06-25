#!/usr/bin/env bash
# Phase 5 — review-setup (HOST, environment-prep only). Drops the human reviewer into a
# ready-to-review state for a bot-authored PR: makes an ISOLATED git worktree on the PR's
# branch (agent/issue-<n>), provisions the gitignored godot_ai addon into it, and opens the
# local Godot editor on it. Then hands off.
#
#   bash scripts/review_setup.sh <issue-number> [--no-launch] [--remove]
#
# No container, no LLM, no credits. This is the HUMAN's machine: in real use your gh/AI
# session is the reviewer (rkibistu); the bot (justfortest1234) lives only in the sandbox.
# You review here, then post review comments in the GitHub UI as yourself — the bot's Fix
# run picks them up ("last author != bot" is the trigger).
set -euo pipefail

# ── config: harness vs game repo (Phase 7). HARNESS_HOME holds scripts + the vendored addon;
#    PROJECT_DIR is the game repo being reviewed (self = the bundled fixture). REPO/GAME_SUBDIR/
#    godot_version come from the game repo's committed .igloo.yml. ──
ROOT="$(cd "$(dirname "$0")/.." && pwd)"            # the harness repo (scripts here)
HARNESS_HOME="${IGLOO_HARNESS_HOME:-$ROOT}"
PROJECT_DIR="${IGLOO_PROJECT_DIR:-$HARNESS_HOME}"   # the game repo (self = fixture)
ENV_FILE="${IGLOO_ENV:-$HARNESS_HOME/.env}"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi   # optional GODOT_BIN/ZIP overrides
export IGLOO_CONFIG_START="$PROJECT_DIR"; unset IGLOO_CONFIG
# shellcheck disable=SC1091
source "$HARNESS_HOME/scripts/lib/config.sh"
REPO="$(cfg_get .repo)"
case "$REPO" in ''|__detect__)
  REPO="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null \
          | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##')" ;;
esac
GAME_SUBDIR="$(cfg_get .game_subdir game)"; case "$GAME_SUBDIR" in .|__detect__) GAME_SUBDIR="";; esac
GODOT_VERSION="$(cfg_get .godot_version 4.6.3-stable)"
ADDON_SRC="$HARNESS_HOME/game/addons/godot_ai"      # vendored in the harness fixture (gitignored in games)
REVIEW_WORKTREE_DIR="${REVIEW_WORKTREE_DIR:-$(dirname "$PROJECT_DIR")/$(basename "$PROJECT_DIR")-review}"
GODOT_ZIP="${GODOT_ZIP:-$HOME/Downloads/Godot_v${GODOT_VERSION}_mono_linux_x86_64.zip}"
GODOT_CACHE="$HARNESS_HOME/.tools/godot"            # where the zip is extracted (gitignored)
# GODOT_BIN may be set in .env to point at any host Godot mono binary directly.
# ────────────────────────────────────────────────────────────────────────────────────────

ISSUE=""; NO_LAUNCH=0; REMOVE=0
for arg in "$@"; do
  case "$arg" in
    --no-launch) NO_LAUNCH=1 ;;
    --remove)    REMOVE=1 ;;
    *)           ISSUE="$arg" ;;
  esac
done
case "$ISSUE" in ''|*[!0-9]*) echo "usage: bash scripts/review_setup.sh <issue-number> [--no-launch] [--remove]" >&2; exit 64;; esac

BRANCH="agent/issue-${ISSUE}"
WT="$REVIEW_WORKTREE_DIR/issue-${ISSUE}"

worktree_registered() { git -C "$PROJECT_DIR" worktree list --porcelain | grep -qxF "worktree $WT"; }

# ── --remove: tear down this issue's review worktree (+ its local branch) and stop ──
if [ "$REMOVE" = 1 ]; then
  if worktree_registered; then
    git -C "$PROJECT_DIR" worktree remove --force "$WT"
    echo "review-setup: removed worktree $WT"
  else
    if [ -d "$WT" ]; then rm -rf "$WT"; fi
    echo "review-setup: no registered worktree for #$ISSUE (cleaned $WT if present)"
  fi
  git -C "$PROJECT_DIR" worktree prune
  git -C "$PROJECT_DIR" branch -D "$BRANCH" >/dev/null 2>&1 || true
  exit 0
fi

# ── resolve + fetch the branch ──
echo "== review-setup #$ISSUE ($BRANCH) =="
git -C "$PROJECT_DIR" fetch --quiet origin || { echo "review-setup: 'git fetch origin' failed." >&2; exit 1; }
if ! git -C "$PROJECT_DIR" rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" >/dev/null; then
  echo "review-setup: branch $BRANCH not found on origin — nothing to review yet (has an agent run opened a PR for #$ISSUE?)." >&2
  exit 1
fi

# ── worktree (idempotent: replace any stale one, reset the local branch to the fetched tip) ──
git -C "$PROJECT_DIR" worktree prune
if worktree_registered; then
  echo "== replace stale worktree $WT =="
  git -C "$PROJECT_DIR" worktree remove --force "$WT"
fi
if [ -d "$WT" ]; then rm -rf "$WT"; fi
mkdir -p "$REVIEW_WORKTREE_DIR"
echo "== worktree add $WT @ origin/$BRANCH =="
git -C "$PROJECT_DIR" worktree add -B "$BRANCH" "$WT" "origin/$BRANCH"

# ── provision the gitignored godot_ai addon into the worktree ──
# project.godot autoloads _mcp_game_helper from this addon; without it the editor throws
# "Failed to instantiate an autoload". It is gitignored -> absent from the fresh worktree.
WT_GAME="$WT${GAME_SUBDIR:+/$GAME_SUBDIR}"            # game project inside the worktree
WT_ADDON="$WT_GAME/addons/godot_ai"
if [ ! -d "$WT_ADDON" ]; then
  if [ -d "$ADDON_SRC" ]; then
    echo "== provision godot_ai addon into worktree =="
    mkdir -p "$WT_GAME/addons"
    cp -r "$ADDON_SRC" "$WT_ADDON"
  else
    echo "review-setup: WARNING — addon source $ADDON_SRC not found; the editor may error on the _mcp_game_helper autoload." >&2
  fi
fi

GAME_DIR="$WT_GAME"
echo "review-setup: worktree ready at $WT"

# ── launch the host Godot editor (unless --no-launch) ──
if [ "$NO_LAUNCH" = 1 ]; then
  echo "review-setup: --no-launch — skipping editor."
else
  # Resolve a host Godot binary: $GODOT_BIN -> cached extract -> extract the zip once.
  if [ -n "${GODOT_BIN:-}" ] && [ -x "${GODOT_BIN}" ]; then
    :
  elif GODOT_BIN="$(find "$GODOT_CACHE" -maxdepth 2 -type f -name 'Godot_v*_mono_linux*' 2>/dev/null | head -1)" && [ -n "$GODOT_BIN" ]; then
    chmod +x "$GODOT_BIN" 2>/dev/null || true
  elif [ -f "$GODOT_ZIP" ]; then
    echo "== extract host Godot from $GODOT_ZIP =="
    mkdir -p "$GODOT_CACHE"
    unzip -oq "$GODOT_ZIP" -d "$GODOT_CACHE"
    GODOT_BIN="$(find "$GODOT_CACHE" -maxdepth 2 -type f -name 'Godot_v*_mono_linux*' 2>/dev/null | head -1)"
    if [ -n "${GODOT_BIN:-}" ]; then chmod +x "$GODOT_BIN" 2>/dev/null || true; fi
  fi
  if [ -z "${GODOT_BIN:-}" ] || [ ! -x "${GODOT_BIN:-/nonexistent}" ]; then
    echo "review-setup: WARNING — no host Godot binary found. Worktree is ready at $WT." >&2
    echo "  Set GODOT_BIN in .env, or place the zip at $GODOT_ZIP, then re-run." >&2
    exit 0
  fi
  echo "== launch Godot editor: $GODOT_BIN --editor --path $GAME_DIR =="
  mkdir -p "$HARNESS_HOME/runs"
  nohup "$GODOT_BIN" --editor --path "$GAME_DIR" >"$HARNESS_HOME/runs/review-issue-${ISSUE}.editor.log" 2>&1 &
  echo "review-setup: editor launching (pid $!); log -> runs/review-issue-${ISSUE}.editor.log"
fi

cat <<EOF

── review #$ISSUE ───────────────────────────────────────────
worktree : $WT
project  : $GAME_DIR
Next: open your IDE here, start your AI session AS THE REVIEWER (rkibistu, not the bot),
and post review comments in the GitHub UI — the bot's Fix run will pick them up.
Clean up when done:  bash scripts/review_setup.sh $ISSUE --remove
─────────────────────────────────────────────────────────────
EOF
