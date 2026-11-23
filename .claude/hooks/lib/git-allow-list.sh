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
#   @no-pathspec  no pathspec operand (a `--`, or more operands than a branch
#                 switch takes): the classifier reads the operands
#
# What earns a fall-through option: it makes git run a program (`--exec`,
# `--upload-pack`, `--receive-pack`, a merge strategy, which git runs as
# `git-merge-<name>` from PATH), opens an editor or pager that would hang an
# unattended run, or writes a file the caller names (`--output`) or writes a path an edit prompt guards (`restore --source`, `checkout <tree-ish> -- <path>`). `apply`, `rm` and `mv` are absent for the same reason: a patch can target `.claude/`, and an operand's text does not say which path git resolves (`-C`, the cwd, `:/`).
#
# Subcommands are chosen from what GAIA's commands, skills, rules, agents and
# executed wiki pages tell Claude to run, and from a scan of session
# transcripts. A subcommand absent here falls through; it is never denied for
# being absent.

# shellcheck disable=SC2034  # read by classify-git-command.sh
GAIA_GIT_ALLOWED_SUBCOMMANDS=(
  'add'
  'archive --exec --remote --output -o'
  'blame --output'
  'branch'
  'cat-file'
  'check-attr'
  'check-ignore'
  'checkout @no-pathspec'
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
  'patch-id'
  'pull --upload-pack --strategy --rebase=i -s'
  'push --receive-pack --exec'
  'rebase --exec --interactive --strategy -x -i -s'
  'remote @read-only'
  'reset'
  'restore --source -s'
  'rev-list --output'
  'rev-parse'
  'revert --strategy -s'
  'shortlog --output'
  'show --output'
  'show-ref'
  'stash --output'
  'status'
  'switch'
  'symbolic-ref'
  'tag'
  'worktree'
)
