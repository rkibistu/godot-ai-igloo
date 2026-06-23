#!/usr/bin/env bash
# Wire the bot's GitHub identity INSIDE the container, from injected env. Idempotent.
# Meant to be SOURCED early in any container that does git/gh work:
#   source /scripts/bot_init.sh
#
# Expects GH_TOKEN already in env (the host wrapper maps BOT_GH_TOKEN -> GH_TOKEN;
# `gh` reads GH_TOKEN natively, so no script ever handles the secret value). Sets the
# bot's commit identity + HTTPS git credentials so pushes/PRs are authored as the bot
# (justfortest1234), never as the human (rkibistu). Never prints the token.
set -uo pipefail

BOT_LOGIN="justfortest1234"
# GitHub noreply: <id>+<login>@users.noreply.github.com — attributes commits to the bot
# without exposing a real email (the bot has no public email set).
BOT_EMAIL="142491623+justfortest1234@users.noreply.github.com"

[ -n "${GH_TOKEN:-}" ] || { echo "bot_init: GH_TOKEN unset (map BOT_GH_TOKEN -> GH_TOKEN via docker run -e)" >&2; return 1 2>/dev/null || exit 1; }

# Prototype gotcha: root + Claude `--dangerously-skip-permissions` needs IS_SANDBOX=1
# (also baked into the image; this is the belt-and-suspenders for non-rebuilt images).
export IS_SANDBOX=1

git config --global user.name  "$BOT_LOGIN"
git config --global user.email "$BOT_EMAIL"

# Route git's HTTPS auth for github.com through the bot token (no SSH key in-container).
gh auth setup-git

WHOAMI="$(gh api user -q .login 2>/dev/null || true)"
if [ "$WHOAMI" != "$BOT_LOGIN" ]; then
  echo "bot_init: authenticated as '${WHOAMI:-<none>}', expected '$BOT_LOGIN'" >&2
  return 1 2>/dev/null || exit 1
fi
echo "bot_init: identity wired — $BOT_LOGIN <$BOT_EMAIL>"
