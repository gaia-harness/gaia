#!/usr/bin/env bash
# The main-checkout hop guard of the main-branch destructive-git guard.
# Sourced only by block-main-destructive-git.sh, after main-git-guard-parse.sh,
# whose parse of the current segment these read; defines functions and does no
# other work at source time.

# shellcheck disable=SC2154  # main_root comes from block-main-destructive-git.sh, the parse globals from main-git-guard-parse.sh

# --- main-checkout hop guard -------------------------------------------------
#
# Several sessions share one main checkout: one can hold it on its own branch
# mid-audit while worktree sessions merge around it, and the feature-branch
# cleanup's `git checkout main` then yanks that HEAD away and forfeits the
# holder's audit round. Prose asking the next session to read HEAD first did not
# hold, so the move is denied here. It is a safety net behind that prose rather
# than a gate: anything it cannot check fails open, with one stderr line.

# The directory a git segment acts on: its last global `-C` path (resolved
# against the payload's cwd when relative), else the payload's cwd, else this
# process's.
hop_target() {
  local directory="$1" base
  base=$GAIA_HOOK_CWD
  [ -n "$base" ] || base="$PWD"
  case "$directory" in
    \"*\") directory="${directory#\"}"; directory="${directory%\"}" ;;
    \'*\') directory="${directory#\'}"; directory="${directory%\'}" ;;
  esac
  case "$directory" in
    '') printf '%s' "$base" ;;
    /*) printf '%s' "$directory" ;;
    *) printf '%s/%s' "$base" "$directory" ;;
  esac
}

# hop_moves_head <target>: 0 when the segment parse_git_globals just read is a
# checkout or switch that moves HEAD. That is a branch-creating or detaching
# form of either one, `-` (the previous branch), or exactly one operand that
# resolves as a commit-ish and is neither HEAD nor the branch HEAD already
# points at. Path restores pass: anything carrying `--`, `-p`, or a pathspec
# file, and two or more operands (a tree-ish plus paths).
#
# Honest limits. The guard reads the command as text, never as the shell would
# expand it, so spellings that need the shell's own reading pass. They include:
# a `git checkout <name>` that git would DWIM into a new tracking branch from a
# remote, since it does not resolve as a commit-ish locally (the feature-branch
# cleanup's `git checkout main` always resolves), where `switch` takes the
# opposite answer and denies an operand that resolves nowhere; a `cd` into the
# main checkout earlier in the same command, since the target comes from `-C` or
# the payload's cwd, never from a `cd`; `--git-dir` or `--work-tree` aiming a
# command run elsewhere at the main checkout, for the same reason; a `-C` whose
# path carries an unexpanded variable or `~`, or is a relative `-C` stacked on an
# earlier one; a global option this parser does not know takes a separated value,
# whose own value then lands in the slot the subcommand is read from; and
# `gh pr checkout`, whose command word is not `git`.
hop_moves_head() {
  local target="$1" operand="" operand_count=0 argument skip_next=0 head_reference operand_reference
  # The two subcommands spell their branch-creating flags differently, and the
  # difference is why they are read apart rather than together: `-c`/`-C` create
  # a branch for `switch` and mean something else entirely for `checkout`, where
  # `-C` is commit's reuse-message option. Past this point the operand analysis
  # is shared, so a switch naming the branch HEAD already holds reaches the same
  # no-op carve-out a checkout naming it does.
  case "$git_subcommand" in
    switch)
      for argument in ${git_args[@]+"${git_args[@]}"}; do
        case "$argument" in
          -c | -C | --create | --force-create | --orphan | --detach) return 0 ;;
        esac
      done
      ;;
    checkout)
      for argument in ${git_args[@]+"${git_args[@]}"}; do
        case "$argument" in -b | -B | --orphan | --detach) return 0 ;; esac
      done
      for argument in ${git_args[@]+"${git_args[@]}"}; do
        case "$argument" in -- | -p | --patch | --pathspec-from-file*) return 1 ;; esac
      done
      ;;
    *) return 1 ;;
  esac
  # Redirections are not operands: `git checkout main 2>/dev/null` names one.
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    case "$argument" in
      *'>' | *'<') skip_next=1; continue ;;
      *[\<\>]*) continue ;;
      -*) [ "$argument" = - ] || continue ;;
    esac
    [ "$operand_count" -eq 0 ] && operand="$argument"
    operand_count=$((operand_count + 1))
  done
  [ "$operand_count" -eq 1 ] || return 1
  [ "$operand" = - ] && return 0
  case "$operand" in
    \"*\") operand="${operand#\"}"; operand="${operand%\"}" ;;
    \'*\') operand="${operand#\'}"; operand="${operand%\'}" ;;
  esac
  if ! git -C "$target" rev-parse --verify -q "${operand}^{commit}" >/dev/null 2>&1; then
    # An unresolvable operand is not a no-op for `switch`: git DWIMs a name
    # carried only by a remote into a new tracking branch and moves HEAD, and a
    # bare name resolves against refs/remotes/<name> rather than
    # refs/remotes/<remote>/<name>, so the test above cannot see one. Denying a
    # name that resolves nowhere at all refuses a command git would reject
    # anyway, which is the safe direction. `checkout` keeps the opposite answer,
    # the DWIM limit its honest-limits block above records.
    if [ "$git_subcommand" = switch ]; then return 0; fi
    return 1
  fi

  # A commit-ish operand still moves nothing when it names HEAD itself, or the
  # branch HEAD already points at, so neither is a hop. Denying them refused a
  # no-op, and the session most likely to hit it is the branch owner's own
  # after a restart, whose new session id no longer matches the breadcrumb.
  [ "$operand" = HEAD ] && return 1
  head_reference=$(git -C "$target" symbolic-ref -q HEAD 2>/dev/null) || head_reference=""
  operand_reference=$(git -C "$target" rev-parse --symbolic-full-name "$operand" 2>/dev/null) || operand_reference=""
  [ -n "$head_reference" ] && [ "$operand_reference" = "$head_reference" ] && return 1
  return 0
}

# The guard's fail-open diagnostic. It takes the WHOLE message rather than a
# branch plus a cause: the arms below do not all fail at the same lookup, and
# one is reached before a branch name has been resolved at all, so a template
# naming one lookup misreports the others.
hop_unchecked() {
  printf 'block-main-destructive-git.sh: %s; allowing the command.\n' "$1" >&2
}

# hop_guard <target>: deny when all of these hold. The target is this
# repository's main checkout, not a linked worktree. Its HEAD is a branch other
# than main, master, or the default origin/HEAD names. That branch has an open
# pull request. And this session is not the one whose `gh pr create` opened it,
# per the breadcrumb .claude/hooks/capture-gh-artifact.sh writes; a missing
# breadcrumb counts as not the owner. The owner's post-merge cleanup passes
# because its pull request is no longer open by then, and subagents share their
# parent's session id, so they count as the owner too.
hop_guard() {
  local target="$1" branch default pull_request_number exit_status session_id breadcrumb_path errexit_was temporary_file
  if ! command -v gaia_is_linked_worktree >/dev/null 2>&1 \
     || ! command -v gaia_resolve_main_root >/dev/null 2>&1; then
    hop_unchecked "could not check whether $target is this repository's main checkout (main-root-lib.sh did not load)"
    return 0
  fi
  gaia_is_linked_worktree "$target" && return 0
  [ "$(gaia_resolve_main_root "$target" 2>/dev/null)" = "$main_root" ] || return 0

  branch=$(git -C "$target" symbolic-ref --short -q HEAD 2>/dev/null) || return 0
  case "$branch" in main | master) return 0 ;; esac
  default=$(git -C "$target" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null) || default=""
  [ -n "$default" ] && [ "$branch" = "${default#origin/}" ] && return 0

  # The owner match is local and decides the verdict whatever the pull request's
  # state, so it runs before the network call rather than after it.
  errexit_was=0
  case $- in *e*) errexit_was=1 ;; esac
  set +e
  if [ -n "$_hook_root" ] && [ -f "$_hook_root/.gaia/scripts/gh-artifact-lib.sh" ]; then
    # shellcheck source=/dev/null
    . "$_hook_root/.gaia/scripts/gh-artifact-lib.sh" 2>/dev/null
  fi
  if [ "$errexit_was" = 1 ]; then set -e; fi
  if command -v gaia_gh_artifact_read >/dev/null 2>&1; then
    session_id=$GAIA_HOOK_SESSION_ID
    if [ -n "$session_id" ]; then
      breadcrumb_path=$(gaia_gh_artifact_path "$(gaia_gh_artifact_cache_directory)" "$branch")
      # A year, not the lib's one-day default: session ids never repeat, so a
      # match proves ownership at any age, however long the file lives.
      [ -n "$(gaia_gh_artifact_read "$breadcrumb_path" "$session_id" "$branch" 31536000)" ] && return 0
    fi
  fi

  if ! command -v gh >/dev/null 2>&1; then
    hop_unchecked "could not check whether '$branch' has an open pull request (gh is not on PATH)"
    return 0
  fi
  # `gh` has no request timeout of its own, and a blackholed network would hold
  # every checkout for an OS-length stall. Five seconds is several times a
  # normal `gh pr list` round-trip; past it the guard gives up and allows.
  #
  # The answer lands in a file rather than a command substitution's pipe. The
  # bound kills only the pid it backgrounded, so a `gh` on PATH that runs the
  # real binary WITHOUT `exec` leaves that grandchild alive still holding the
  # pipe, and a substitution waits for every process holding it: the bound
  # would not hold, and the diagnostic would claim one that had.
  temporary_file=$(mktemp -t gaia-hop-pr-XXXXXX 2>/dev/null) || temporary_file=""
  if [ -z "$temporary_file" ]; then
    hop_unchecked "could not check whether '$branch' has an open pull request (no temporary file could be created for the gh pr list output)"
    return 0
  fi
  (
    cd "$target" || exit 125
    gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty' >"$temporary_file" 2>/dev/null &
    pid=$!
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$ticks" -ge 50 ]; then
        kill "$pid" 2>/dev/null || true
        exit 124
      fi
      sleep 0.1
      ticks=$((ticks + 1))
    done
    wait "$pid"
  ) && exit_status=0 || exit_status=$?
  pull_request_number=$(cat "$temporary_file" 2>/dev/null) || pull_request_number=""
  rm -f "$temporary_file"
  case "$exit_status" in
    0) ;;
    124) hop_unchecked "could not check whether '$branch' has an open pull request (gh pr list timed out after 5s)"; return 0 ;;
    125) hop_unchecked "could not check whether '$branch' has an open pull request ($target could not be entered to run gh pr list)"; return 0 ;;
    *) hop_unchecked "could not check whether '$branch' has an open pull request (the open pull-request lookup, gh pr list, exited $exit_status)"; return 0 ;;
  esac
  [ -n "$pull_request_number" ] || return 0
  if ! [[ "$pull_request_number" =~ ^[0-9]+$ ]]; then
    hop_unchecked "could not check whether '$branch' has an open pull request (gh pr list answered with something other than a pull-request number)"
    return 0
  fi
  # The open pull request is in hand by here, so the lookup that can still fail
  # is whose session opened it, not whether one is open.
  if ! command -v gaia_gh_artifact_read >/dev/null 2>&1; then
    hop_unchecked "could not check whether this session opened the open pull request on '$branch' (gh-artifact-lib.sh did not load)"
    return 0
  fi

  deny "The main checkout is holding branch '$branch', which has open pull request #$pull_request_number: another session is working there, and moving this checkout's HEAD would pull the branch '$branch' from under it and forfeit its audit round. If you are cleaning up after a merge, take the worktree arm in .claude/skills/gaia/references/work-lifecycle.md (## 8. Cleanup), which runs no git checkout. If this is your own branch, run the command yourself with the ! prefix."
}
