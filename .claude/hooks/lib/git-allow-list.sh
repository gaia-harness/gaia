#!/usr/bin/env bash
# The git subcommands classify-git-command.sh approves without a prompt, the one
# list it reads. Defines data and does no work at source time.
#
# Each entry is a subcommand, then the options that make it fall through to the
# permission prompt even though the subcommand is listed:
#   --long        the long option, in any prefix git's option parser accepts
#                 (`--upl` is `--upload-pack`), with or without `=value`
#   --long=value  the long option only when its value starts with `value`
#   -x            the short letter, alone or inside a bundle (`-ix`)
#   @read-only    only the forms that write nothing: the classifier owns the
#                 per-subcommand reading
#
# What earns a fall-through option: it makes git run a program (`--exec`,
# `--upload-pack`, `--receive-pack`, a merge strategy, which git runs as
# `git-merge-<name>` from PATH), opens an editor or pager that would hang an
# unattended run, or writes a file the caller names (`--output`).
#
# Subcommands are chosen from what GAIA's commands, skills, rules, agents and
# executed wiki pages tell Claude to run, and from a scan of session
# transcripts. A subcommand absent here falls through; it is never denied for
# being absent.

# shellcheck disable=SC2034  # read by classify-git-command.sh
GAIA_GIT_ALLOWED_SUBCOMMANDS=(
  'add'
  'apply --unsafe-paths'
  'archive --exec --remote --output -o'
  'blame'
  'branch'
  'cat-file'
  'check-attr'
  'check-ignore'
  'checkout'
  'cherry'
  'cherry-pick --strategy -s'
  'commit'
  'config @read-only'
  'describe'
  'diff --output'
  'fetch --upload-pack'
  'for-each-ref'
  'grep --open-files-in-pager -O'
  'hash-object'
  'log --output'
  'ls-files'
  'ls-remote --upload-pack'
  'ls-tree'
  'merge --strategy -s'
  'merge-base'
  'merge-tree'
  'mv'
  'patch-id'
  'pull --upload-pack --strategy --rebase=i -s'
  'push --receive-pack --exec'
  'rebase --exec --interactive --strategy -x -i -s'
  'remote @read-only'
  'reset'
  'restore'
  'rev-list'
  'rev-parse'
  'revert --strategy -s'
  'rm'
  'shortlog'
  'show --output'
  'show-ref'
  'stash'
  'status'
  'switch'
  'symbolic-ref'
  'tag'
  'worktree'
)
