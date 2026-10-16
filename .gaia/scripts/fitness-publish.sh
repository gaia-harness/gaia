#!/usr/bin/env bash
#
# Publish mechanics for the /gaia-fitness heal diff
# (.claude/skills/gaia/references/fitness.md, Step 9). It owns only the
# commit, the push and the draft pull request, so a bats suite with a bare
# remote and a `gh` shim can assert what each publish option does. It has no
# merge subcommand and never calls the merge verb: the playbook runs the merge
# as its own Bash call, because the local merge gate and every merge-keyed hook
# arm only on a Bash command whose text holds that verb, and the audit
# handshake sits between this script's `open` and that call.
#
# Usage:
#   fitness-publish.sh open   --branch <name> --message-file <path> --title <text> --body-file <path> [--root <dir>]
#   fitness-publish.sh commit --message-file <path> [--root <dir>]
#
#   open    git add -A, git commit -F <message-file>, git push -u origin
#           <name>, gh pr create --draft. Prints the pull request number alone
#           on stdout. The pull request opens as a draft because the
#           `GAIA-Audit` success post is what marks it ready.
#   commit  git add -A, git commit -F <message-file>, git push -u origin on the
#           current branch, for a heal applied in place on a non-default
#           branch. Opens no pull request.
#   --root  the working tree to publish; defaults to the git top level of the
#           working directory. Every git call goes through `git -C <root>`.
#
# Exit codes:
#   0  published
#   1  a git or gh call failed; stderr names the failing command. Nothing is
#      retried, force-pushed or amended: the caller reports the failure and the
#      user resolves it.
#   2  usage error (unknown subcommand, a missing option, an unreadable file,
#      a branch name that looks like an option); nothing was run.

set -euo pipefail

usage_error() {
  echo "fitness-publish: $1" >&2
  echo "usage: fitness-publish.sh open --branch <name> --message-file <path> --title <text> --body-file <path> [--root <dir>]" >&2
  echo "       fitness-publish.sh commit --message-file <path> [--root <dir>]" >&2
  exit 2
}

# Named failure: the failing command on stderr, exit 1. Used by every git and
# gh call so a caller never has to guess which step stopped the publish.
fail_command() {
  echo "fitness-publish: failed: $1" >&2
  exit 1
}

subcommand="${1:-}"
[ -n "$subcommand" ] || usage_error "a subcommand is required"
shift
case "$subcommand" in
  open | commit) ;;
  *) usage_error "unknown subcommand: $subcommand" ;;
esac

branch=""
message_file=""
title=""
body_file=""
root=""

while [ $# -gt 0 ]; do
  case "$1" in
    --branch=* | --message-file=* | --title=* | --body-file=* | --root=*)
      option_name="${1%%=*}"
      option_value="${1#*=}"
      set -- "$option_name" "$option_value" "${@:2}"
      continue
      ;;
    --branch | --message-file | --title | --body-file | --root)
      [ $# -ge 2 ] || usage_error "$1 needs a value"
      case "$1" in
        --branch) branch="$2" ;;
        --message-file) message_file="$2" ;;
        --title) title="$2" ;;
        --body-file) body_file="$2" ;;
        --root) root="$2" ;;
      esac
      shift 2
      ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done

[ -n "$message_file" ] || usage_error "--message-file is required"
[ -r "$message_file" ] || usage_error "message file is not readable: $message_file"
if [ "$subcommand" = "open" ]; then
  [ -n "$branch" ] || usage_error "--branch is required"
  [ -n "$title" ] || usage_error "--title is required"
  [ -n "$body_file" ] || usage_error "--body-file is required"
  [ -r "$body_file" ] || usage_error "body file is not readable: $body_file"
  # A leading dash would be read by git and gh as an option, not a branch.
  case "$branch" in
    -*) usage_error "branch name must not start with a dash: $branch" ;;
  esac
fi

if [ -z "$root" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || usage_error "not inside a git work tree and no --root given"
fi

git -C "$root" add -A || fail_command "git add -A"
git -C "$root" commit -q -F "$message_file" || fail_command "git commit -F"

if [ "$subcommand" = "commit" ]; then
  current_branch="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null)" || fail_command "git symbolic-ref --short HEAD"
  git -C "$root" push -q -u origin "$current_branch" || fail_command "git push -u origin $current_branch"
  exit 0
fi

git -C "$root" push -q -u origin "$branch" || fail_command "git push -u origin $branch"

# gh has no -C flag, so the pull request is created from inside the work tree.
pr_output="$(cd "$root" && gh pr create --draft --head "$branch" --title "$title" --body-file "$body_file")" ||
  fail_command "gh pr create --draft"

pr_number="${pr_output##*/}"
case "$pr_number" in
  '' | *[!0-9]*) fail_command "reading the pull request number from the gh pr create output" ;;
esac
printf '%s\n' "$pr_number"
