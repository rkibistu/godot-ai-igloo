#!/usr/bin/env bash
# One-line installer for the godot-ai-igloo harness (Phase 7 / ADR-0004). Installs ONCE per
# machine; you then point `igloo` at any Godot C# repo. Idempotent.
#
#   bash install.sh              # clone the harness into ~/.igloo/harness, fetch yq, build image
#   bash install.sh --dev        # symlink ~/.igloo/harness -> the current repo (live edits; for
#                                #   developing the harness — `igloo update` is then a no-op pull)
#   bash install.sh --no-build   # skip the first image build
set -euo pipefail
IGLOO_HOME="${IGLOO_HOME:-$HOME/.igloo}"
HARNESS_REPO="${HARNESS_REPO:-https://github.com/rkibistu/godot-ai-igloo.git}"
YQ_VERSION="${YQ_VERSION:-v4.44.6}"

DEV_SRC=""; NO_BUILD=0
for a in "$@"; do case "$a" in
  --dev=*)   DEV_SRC="${a#--dev=}" ;;
  --dev)     DEV_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" ;;   # the repo this script is in
  --no-build) NO_BUILD=1 ;;
esac; done

mkdir -p "$IGLOO_HOME/bin" "$HOME/.local/bin"

# 1) harness: dev symlink, existing clone (pull), or fresh clone
if [ -n "$DEV_SRC" ]; then
  DEV_SRC="$(cd "$DEV_SRC" && pwd)"
  ln -sfn "$DEV_SRC" "$IGLOO_HOME/harness"
  echo "harness -> $DEV_SRC (dev symlink)"
elif [ -d "$IGLOO_HOME/harness/.git" ]; then
  git -C "$IGLOO_HOME/harness" pull --ff-only || true
  echo "harness updated (existing clone at $IGLOO_HOME/harness)"
else
  git clone "$HARNESS_REPO" "$IGLOO_HOME/harness"
  echo "harness cloned -> $IGLOO_HOME/harness"
fi

# 2) yq (mikefarah static binary) — the one dependency, fetched here so there's nothing to install
if [ ! -x "$IGLOO_HOME/bin/yq" ]; then
  curl -fsSL -o "$IGLOO_HOME/bin/yq" \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
  chmod +x "$IGLOO_HOME/bin/yq"
  echo "fetched yq $YQ_VERSION -> $IGLOO_HOME/bin/yq"
fi

# 3) dispatcher on PATH
chmod +x "$IGLOO_HOME/harness/bin/igloo" 2>/dev/null || true
ln -sfn "$IGLOO_HOME/harness/bin/igloo" "$HOME/.local/bin/igloo"
echo "igloo -> $HOME/.local/bin/igloo  (ensure ~/.local/bin is on your PATH)"

# 4) global secrets (filled once; NEVER in any .igloo.yml)
if [ ! -f "$IGLOO_HOME/.env" ]; then
  cp "$IGLOO_HOME/harness/.env.example" "$IGLOO_HOME/.env" 2>/dev/null || touch "$IGLOO_HOME/.env"
  chmod 600 "$IGLOO_HOME/.env"
  echo "created $IGLOO_HOME/.env — fill BOT_GH_TOKEN + CLAUDE_CODE_OAUTH_TOKEN"
fi

# 5) first image build
if [ "$NO_BUILD" = 1 ]; then
  echo "skipping image build (--no-build); run 'igloo build' when ready."
else
  GODOT_VERSION="${GODOT_VERSION:-4.6.3-stable}" bash "$IGLOO_HOME/harness/docker/build.sh" \
    || echo "image build skipped/failed — run 'igloo build' later."
fi

echo "install done. Next: cd into a Godot C# repo and run 'igloo init'."
