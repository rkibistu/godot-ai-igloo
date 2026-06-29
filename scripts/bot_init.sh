#!/usr/bin/env bash
# Wire the bot's GitHub identity INSIDE the container, from injected env. Idempotent.
# Meant to be SOURCED early in any container that does git/gh work:
#   source /scripts/bot_init.sh
#
# Expects GH_TOKEN already in env (the host wrapper maps BOT_GH_TOKEN -> GH_TOKEN;
# `gh` reads GH_TOKEN natively, so no script ever handles the secret value). Sets the
# bot's commit identity + HTTPS git credentials so pushes/PRs are authored as the bot,
# never as the human reviewer. Never prints the token.
#
# Phase 7: the bot login/id are DERIVED from the authenticated token (`gh api user`), not
# hardcoded — so one global bot works across all games and the identity cannot drift from the
# token (ADR-0004 decision 5). Leaves $BOT_LOGIN / $BOT_EMAIL in scope for the caller.
set -uo pipefail

[ -n "${GH_TOKEN:-}" ] || { echo "bot_init: GH_TOKEN unset (map BOT_GH_TOKEN -> GH_TOKEN via docker run -e)" >&2; return 1 2>/dev/null || exit 1; }

# Prototype gotcha: root + Claude `--dangerously-skip-permissions` needs IS_SANDBOX=1
# (also baked into the image; this is the belt-and-suspenders for non-rebuilt images).
export IS_SANDBOX=1

# Derive identity from the token (one call -> login + numeric id). This also validates the token.
read -r BOT_LOGIN BOT_ID <<<"$(gh api user --jq '"\(.login) \(.id)"' 2>/dev/null)"
[ -n "${BOT_LOGIN:-}" ] || { echo "bot_init: 'gh api user' returned no login (bad/expired GH_TOKEN?)" >&2; return 1 2>/dev/null || exit 1; }
# GitHub noreply: <id>+<login>@users.noreply.github.com — attributes commits to the bot
# without exposing a real email (the bot need not have a public email set).
BOT_EMAIL="${BOT_ID}+${BOT_LOGIN}@users.noreply.github.com"

git config --global user.name  "$BOT_LOGIN"
git config --global user.email "$BOT_EMAIL"

# Route git's HTTPS auth for github.com through the bot token (no SSH key in-container).
gh auth setup-git

echo "bot_init: identity wired — $BOT_LOGIN <$BOT_EMAIL>"
