#!/usr/bin/env bash
# shellcheck shell=bash
#
# GAIA hook-only fast main-root read.
#
# gaia_resolve_main_root_fast [directory]
#   A bash-only read of the layout off disk, for the rate-limit checkpoint
#   hook's silent-path pre-check. The hook is its only caller; it is NOT a
#   resolver for general use, and gaia_resolve_main_root never calls it.
#
#   Absent-only: a caller may use its answer only to conclude that a file it
#   looks for is absent under that root. On every other outcome, including a
#   root where the file exists, the caller must run gaia_resolve_main_root.
#
#   It reads the nearest .git entry at or above the physical directory and
#   prints a root only for a plain checkout or a linked worktree of one, with
#   an intact git directory and no occurrence of the word worktree or include
#   (any case) anywhere in the owning config. On any other layout, or any
#   unreadable file, it prints nothing and returns 1.
#
#   It depends on main-root-lib.sh's private helpers (_gaia_absolute_path,
#   _gaia_physical_directory), so main-root-lib.sh must be sourced first. It
#   never runs a git process.

# Every `return 1` is "defer to the full resolution", never "no root".
gaia_resolve_main_root_fast() {
  local walk
  walk="$(_gaia_physical_directory "$(_gaia_absolute_path "${1:-$PWD}" "$PWD")")" || return 1
  case "$walk/" in */.git/*) return 1 ;; esac

  local git_directory root
  while :; do
    if [[ -d "$walk/.git" ]]; then
      root="$walk"
      git_directory="$walk/.git"
      break
    elif [[ -e "$walk/.git" ]]; then
      local pointer name main_git_directory commondir back_link
      [[ -f "$walk/.git" ]] && IFS= read -r pointer <"$walk/.git" || return 1
      case "$pointer" in "gitdir: /"*/.git/worktrees/*) ;; *) return 1 ;; esac
      git_directory="${pointer#gitdir: }"
      name="${git_directory##*/worktrees/}"
      case "$name" in '' | */*) return 1 ;; esac
      main_git_directory="${git_directory%/worktrees/*}"
      [[ "$main_git_directory" == */.git ]] || return 1
      [[ -f "$git_directory/HEAD" ]] || return 1
      IFS= read -r commondir <"$git_directory/commondir" || return 1
      [[ "$commondir" == ../.. ]] || return 1
      IFS= read -r back_link <"$git_directory/gitdir" || return 1
      [[ "$back_link" == "$walk/.git" ]] || return 1
      root="$(_gaia_physical_directory "${main_git_directory%/.git}")" || return 1
      [[ "$(_gaia_physical_directory "$main_git_directory")" == "$root/.git" ]] || return 1
      git_directory="$main_git_directory"
      break
    fi
    [[ "$walk" == / ]] && return 1
    walk="${walk%/*}"
    [[ -n "$walk" ]] || walk=/
  done

  # A worktree or include key (any case) in the owning config can move the
  # work tree: defer on the word rather than parse the config.
  [[ -f "$git_directory/HEAD" && -r "$git_directory/config" ]] || return 1
  local config_text deferring_pattern='[Ww][Oo][Rr][Kk][Tt][Rr][Ee][Ee]|[Ii][Nn][Cc][Ll][Uu][Dd][Ee]'
  config_text="$(<"$git_directory/config")" || return 1
  ! [[ "$config_text" =~ $deferring_pattern ]] || return 1

  printf '%s\n' "$root"
}
