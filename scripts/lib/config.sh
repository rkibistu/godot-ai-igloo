#!/usr/bin/env bash
# Shared .igloo.yml reader (Phase 7). SOURCED by both in-container scripts (gate.sh,
# agent_run.sh, agent_real.sh) and host scripts (bin/igloo, review_setup.sh, agent_run_host.sh).
# Single source of the mechanical contract — see docs/adr/0004 ("Instructions for future
# implementations"): a field the gate verifies AND the agent must produce is read from HERE by
# both the gate and the prompt-builder, and is never restated in a skill.
#
#   source "$(dirname "$0")/lib/config.sh"   # (path-relative; works mounted or installed)
#   cfg_get .issue_scene.class "Issue{n}"    # value, or the default if absent/null
#   cfg_subst "$(cfg_get .issue_scene.scene)" "$ISSUE"   # expand the {n} placeholder
#   cfg_list .gate.extra_clauses             # newline-separated sequence items (empty if none)
#
# Parsing is done with `yq` (mikefarah). Resolution order: $IGLOO_YQ, PATH, ~/.igloo/bin/yq,
# /usr/local/bin/yq (the image bakes it there). Config resolution: $IGLOO_CONFIG, else the
# nearest .igloo.yml walking up from $IGLOO_CONFIG_START (default $PWD).

# --- locate the yq binary -----------------------------------------------------
_igloo_yq() {
  if [ -n "${IGLOO_YQ:-}" ] && [ -x "${IGLOO_YQ}" ]; then command "${IGLOO_YQ}" "$@"; return; fi
  if command -v yq >/dev/null 2>&1; then command yq "$@"; return; fi
  if [ -x "$HOME/.igloo/bin/yq" ]; then command "$HOME/.igloo/bin/yq" "$@"; return; fi
  if [ -x /usr/local/bin/yq ]; then command /usr/local/bin/yq "$@"; return; fi
  echo "igloo-config: yq not found (run install.sh / 'igloo build', or set IGLOO_YQ)" >&2
  return 127
}

# --- locate the active .igloo.yml --------------------------------------------
cfg_file() {
  if [ -n "${IGLOO_CONFIG:-}" ]; then printf '%s' "$IGLOO_CONFIG"; return 0; fi
  local d="${IGLOO_CONFIG_START:-$PWD}"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/.igloo.yml" ]; then printf '%s' "$d/.igloo.yml"; return 0; fi
    d="$(dirname "$d")"
  done
  [ -f "/.igloo.yml" ] && { printf '%s' "/.igloo.yml"; return 0; }
  echo "igloo-config: no .igloo.yml found from ${IGLOO_CONFIG_START:-$PWD} (run 'igloo init')" >&2
  return 1
}

# --- readers ------------------------------------------------------------------
# cfg_get <yq-path-expr> [default]  -> scalar value, or the default when the key is absent/null/
# empty OR no .igloo.yml is found at all (so standalone callers fall back to their literal default).
cfg_get() {
  local f v
  if ! f="$(cfg_file 2>/dev/null)"; then printf '%s' "${2:-}"; return 0; fi
  v="$(_igloo_yq e "$1" "$f" 2>/dev/null)" || { printf '%s' "${2:-}"; return 0; }
  if [ -z "$v" ] || [ "$v" = "null" ]; then printf '%s' "${2:-}"; else printf '%s' "$v"; fi
}

# cfg_list <yq-path-to-sequence>  -> one item per line. Missing key / missing file -> nothing.
cfg_list() {
  local f
  f="$(cfg_file 2>/dev/null)" || return 0
  _igloo_yq e "($1) // [] | .[]" "$f" 2>/dev/null
}

# cfg_subst <template> <issue#>  -> expand the {n} placeholder (the ONLY templating we do).
cfg_subst() { printf '%s' "${1//\{n\}/$2}"; }
