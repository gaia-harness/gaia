#!/usr/bin/env bash
# The foreign-repo guard's per-command reader: one scanned command's verdict,
# and where a directory it names sits.
# Sourced only by repo-scope.sh, whose header states the contract every
# consumer relies on; defines functions and globals and does no other work at
# source time.

# shellcheck disable=SC2154,SC2034  # the walk state is local to the guard in repo-scope.sh

# Classifies the command the scan just read: 0 touches no repository, 1 acts
# on another repository, 2 acts on this one or cannot be read (enforce).
#
# Only a command whose first word is `git` or `gh` is read for where it acts.
# Any other command that names either program anywhere in its words (a
# subshell, `env` or `VAR=` prefix, `$( )`, backticks, `bash -c`, `xargs`) is
# a shape this walk does not model, so it is home. A heredoc body's lines reach
# here as commands and are classified like any other: a body line reading as a
# foreign `gh -R` counts as foreign, one naming git or gh any other way
# enforces, and one starting `cd` moves nothing, because the heredoc left the
# walk opaque.
_gaia_repo_scope_segment() {
  local word_count=${#GAIA_FIRST_COMMAND_WORDS[@]}
  local i token target cdir="" ccount=0 ghrepo="" name scope_status

  case "${GAIA_FIRST_COMMAND_WORDS[0]}" in
    cd)
      # Only a `cd` the calling shell certainly runs, ahead of every command
      # after it, moves the directory (see the guard's walk). Any other leaves it
      # unknown, and so does one that is opaque itself (`cd x)` closes a
      # subshell).
      if [ "$opaque" = 1 ] || _gaia_repo_scope_opens_group; then directory_known=0; return 0; fi
      case "$separator_before:$separator_after" in
        start:seq|start:and|start:end|seq:seq|seq:and|seq:end|and:seq|and:and|and:end) ;;
        *) directory_known=0; return 0 ;;
      esac
      if [ "$word_count" -ne 2 ]; then directory_known=0; return 0; fi
      target="${GAIA_FIRST_COMMAND_WORDS[1]}"
      # A bare `cd`, `cd -`, and a target the shell rewrites before cd sees it
      # land somewhere this walk cannot name, so every command after one is
      # home until an absolute `cd` names a directory again.
      _gaia_repo_scope_expand_directory || { directory_known=0; return 0; }
      case "$target" in
        /*) directory="$target"; directory_known=1 ;;
        *) [ "$directory_known" = 1 ] && directory="${directory:+$directory/}$target" ;;
      esac
      list_moved=1
      [ "$separator_before" = and ] && conditional_move=1
      return 0
      ;;
    pushd|popd)
      directory_known=0
      return 0
      ;;
    git)
      # git's global options come before the subcommand. An unmodelled one that
      # takes a separate value ends this walk early and hides a later `-C`,
      # which reads the command against the tracked directory instead.
      i=1
      while [ "$i" -lt "$word_count" ]; do
        token="${GAIA_FIRST_COMMAND_WORDS[$i]}"
        case "$token" in
          -C)
            ccount=$((ccount + 1))
            cdir="${GAIA_FIRST_COMMAND_WORDS[$((i + 1))]:-}"
            i=$((i + 2))
            ;;
          -c|--config-env|--attr-source|--namespace) i=$((i + 2)) ;;
          --git-dir|--git-dir=*|--work-tree|--work-tree=*) return 2 ;;
          -*) i=$((i + 1)) ;;
          *) break ;;
        esac
      done
      # git applies multiple -C cumulatively with the LAST winning, which this
      # walk does not model, so more than one is ambiguous: enforce.
      [ "$ccount" -gt 1 ] && return 2
      if [ "$ccount" = 1 ]; then
        target="$cdir"
        _gaia_repo_scope_expand_directory || return 2
        case "$target" in
          /*) ;;
          *) [ "$directory_known" = 1 ] || return 2; target="${directory:+$directory/}$target" ;;
        esac
        scope_status=0
        _gaia_repo_scope_where "$target" || scope_status=$?
        [ "$scope_status" = 0 ] && return 1
        return 2
      fi
      scope_status=0
      _gaia_repo_scope_tracked || scope_status=$?
      [ "$scope_status" = 0 ] && return 1
      return 2
      ;;
    gh)
      # `-R`/`--repo` (space OR `=` form). gh ignores cwd when this is given,
      # so it is authoritative for the command carrying it. It is read from
      # this command's own words, which the scan unquoted, so `--repo` inside
      # a quoted `--body` stays text and another program's `-R` operand (`cp
      # -R a/b x`) is never in reach.
      i=1
      while [ "$i" -lt "$word_count" ]; do
        token="${GAIA_FIRST_COMMAND_WORDS[$i]}"
        i=$((i + 1))
        case "$token" in
          # gh's flag library keeps the LAST spelling it reads, so the walk
          # does not stop at the first one.
          -R|--repo)
            [ "$i" -lt "$word_count" ] && ghrepo="${GAIA_FIRST_COMMAND_WORDS[$i]}"
            ;;
          -R=*|--repo=*) ghrepo="${token#*=}" ;;
          # An ATTACHED shorthand (`-Rowner/repo`) is not read. Only the flags
          # a given gh subcommand takes a value for decide whether such a word
          # is a repository or some other flag's value (`--subject
          # -Rfoo/bar`), and this entry point serves every subcommand, so it
          # models no per-subcommand flag set. It may name either repository,
          # so enforce.
          -R?*) return 2 ;;
        esac
      done
      if [ -z "$ghrepo" ]; then
        scope_status=0
        _gaia_repo_scope_tracked || scope_status=$?
        [ "$scope_status" = 0 ] && return 1
        return 2
      fi
      # Only the characters a [HOST/]OWNER/REPO or a URL spelling of one
      # holds. Anything else (a quote left over, an escape, `$`, a backtick, a
      # brace, a glob, a tilde) is a value the shell may rewrite before gh sees
      # it, so what gh names is unknown. An allowlist, because each blocklist
      # of those left the next expansion out.
      case "$ghrepo" in *[![:alnum:]._:/-]*) return 2 ;; esac
      # gh refuses a value with no owner, so it names no repository to exempt.
      case "$ghrepo" in */*) ;; *) return 2 ;; esac
      name=$(_gaia_repo_scope_repo_name "$ghrepo")
      [ -n "$name" ] || return 2
      # The home repo's names are the repository names its remotes point at.
      # Remotes live in the shared git config, so every worktree reads the
      # same set, and none of them depends on what a checkout's directory is
      # called. Every remote counts rather than only the one `gh` would pick,
      # because a fork clone's `gh pr merge` resolves to its `upstream`
      # remote, not `origin`.
      #
      # Comparison is repo-NAME only: a same-named fork (`-R
      # myfork/<homename>`) classifies as home and over-enforces, fail-closed
      # and safe, but worth knowing for fork workflows. `gh repo view` would
      # name the whole slug, but it is a network call on a blocking hook's
      # path and it names one repository where a fork clone has two.
      if [ "$remotes_read" = 0 ]; then
        remotes=$(git config --get-regexp '^remote\..+\.url$' 2>/dev/null \
          | while read -r _ url; do _gaia_repo_scope_repo_name "$url"; echo; done)
        remotes_read=1
      fi
      # No remote names the home repo, so there is nothing to call foreign.
      [ -n "$remotes" ] || return 2
      # A shell match rather than grep: a matcher that fails to run would read
      # as "no match" and exempt the command.
      case "$NEWLINE$remotes$NEWLINE" in *"$NEWLINE$name$NEWLINE"*) return 2 ;; esac
      return 1
      ;;
  esac

  for token in ${GAIA_FIRST_COMMAND_WORDS[@]+"${GAIA_FIRST_COMMAND_WORDS[@]}"}; do
    if [[ "$token" =~ $_GAIA_REPO_SCOPE_TOOL_REGEX ]]; then
      _gaia_repo_scope_tracked || true
      return 2
    fi
  done
  return 0
}

# Rewrites the caller's `target` the way the shell would before cd or git sees
# it, as far as that is knowable: returns 1 for a value the shell rewrites in a
# way this cannot follow, and for `-` and the empty string.
#
# The tilde arrives as a literal character in the command text, since bash
# never expanded it inside the tool_input string, so it is stripped by offset.
# SC2088 fires on the quoted tilde, but these are case PATTERNS matching a
# literal '~' in the input string, not an expansion attempt, intentional.
# shellcheck disable=SC2088
_gaia_repo_scope_expand_directory() {
  case "$target" in
    '~') target="$HOME" ;;
    '~/'*) target="$HOME/${target:2}" ;;
  esac
  case "$target" in
    '' | -* | *'$'* | *'`'* | *\\* | *'*'* | *'?'* | *'['* | *'{'* | *'~'*) return 1 ;;
  esac
  return 0
}

# Where the directory `$1` sits: 0 another repository, 1 this repository, 2
# unresolvable. Same repository means same git common directory, which a main
# checkout shares with every linked worktree of it. The resolver's identity
# answer rather than two main-root resolutions: this runs on nearly every git
# tool call. Without the resolver, or for a target whose repository cannot be
# resolved, there is no identity to compare, so the caller enforces.
_gaia_repo_scope_where() {
  local target_common_directory
  _gaia_repo_scope_load_main_root || return 2
  if [ "$home_common_read" = 0 ]; then
    home_common=$(gaia_resolve_common_directory) || home_common=""
    home_common_read=1
  fi
  [ -n "$home_common" ] || return 2
  target_common_directory=$(gaia_resolve_common_directory "$1") || return 2
  [ -n "$target_common_directory" ] || return 2
  [ "$target_common_directory" = "$home_common" ] && return 1
  return 0
}

# Where the walk's tracked directory sits, with `_gaia_repo_scope_where`'s
# codes. The hook's own directory, with no `cd` ahead, is this repository. A
# `cd` target that resolves as this repository is published for the caller
# (GAIA_REPO_SCOPE_LEAD_CD, in repo-scope.sh); an unresolvable one never is, because a
# caller reading its branch from a path git cannot open would read no branch
# at all and let the command through.
_gaia_repo_scope_tracked() {
  local scope_status=0
  [ "$directory_known" = 1 ] || return 2
  [ -n "$directory" ] || return 1
  _gaia_repo_scope_where "$directory" || scope_status=$?
  # shellcheck disable=SC2034 # read by worthiness-presence-check.sh
  [ "$scope_status" = 1 ] && GAIA_REPO_SCOPE_LEAD_CD="$directory"
  return "$scope_status"
}
