#!/usr/bin/env bash
# shellcheck shell=bash
#
# State-line functions for the update commands' main-only refusal.
#
# Each prints one line summarizing the cached update state on main, and is
# passed by name as the second argument of gaia_refuse_if_worktree
# (main-only-lib.sh), which calls it with the absolute path of main's
# update-check.json. A function prints nothing when the cache is unusable, and
# the refusal falls back to its shared line.
#
# These live in a sourced file rather than inline in the skills' guard fences
# because the runtime inspects a command's text: a function defined inline
# with captured command substitutions gets the whole guard block refused
# inside a worktree session, before the guard can return. Code in a sourced
# file is not inspected.
#
# Sourced by markdown call sites that an agent runs through its login shell,
# zsh on a stock Mac, so nothing here may rely on BASH_SOURCE or `declare -F`
# (see the header of main-only-lib.sh), and it must run under bash 3.2.

gaia_update_deps_state_line() {
  local cache_file="$1"
  [ -f "$cache_file" ] && command -v jq >/dev/null 2>&1 || return 0
  local outdated_count checked_at security_count security_term
  outdated_count="$(jq -r '.outdatedCount // 0' "$cache_file" 2>/dev/null)"
  checked_at="$(jq -r '.checkedAt // 0' "$cache_file" 2>/dev/null)"
  # A null security count means no source answered, which is not zero.
  security_count="$(jq -r 'if (.securityCount | type) == "number" and .securitySource != "unavailable" then (.securityCount | tostring) else "null" end' "$cache_file" 2>/dev/null)"
  [ -n "$outdated_count" ] && [ -n "$checked_at" ] && [ "$checked_at" != "0" ] || return 0
  if [ -z "$security_count" ] || [ "$security_count" = "null" ]; then
    security_term="security advisories unavailable"
  else
    security_term="$security_count open security advisories"
  fi
  local now age ago_unit ago_value
  now=$(date +%s)
  age=$((now - checked_at))
  # Format age as <Nm ago> / <Nh ago> / <Nd ago>.
  ago_unit="s"; ago_value="$age"
  if [ "$age" -ge 86400 ]; then ago_unit="d"; ago_value=$((age / 86400));
  elif [ "$age" -ge 3600 ]; then ago_unit="h"; ago_value=$((age / 3600));
  elif [ "$age" -ge 60 ]; then ago_unit="m"; ago_value=$((age / 60));
  fi
  printf 'Cached on main: %s packages outdated, %s (last checked %s%s ago).\n' "$outdated_count" "$security_term" "$ago_value" "$ago_unit"
}

gaia_update_gaia_state_line() {
  local cache_file="$1"
  [ -f "$cache_file" ] && command -v jq >/dev/null 2>&1 || return 0
  local gaia_current gaia_latest gaia_has_update
  gaia_current="$(jq -r '.gaiaCurrent // ""' "$cache_file" 2>/dev/null)"
  gaia_latest="$(jq -r '.gaiaLatest // ""' "$cache_file" 2>/dev/null)"
  gaia_has_update="$(jq -r '.gaiaHasUpdate // false' "$cache_file" 2>/dev/null)"
  [ -n "$gaia_current" ] && [ -n "$gaia_latest" ] || return 0
  local update_phrase="not-available"
  [ "$gaia_has_update" = "true" ] && update_phrase="available"
  printf 'Cached on main: GAIA %s installed; latest %s (update %s).\n' "$gaia_current" "$gaia_latest" "$update_phrase"
}
