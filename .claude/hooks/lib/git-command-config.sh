#!/usr/bin/env bash
# The git config keys whose value git runs as a program or a shell command, and
# the keys an approved `-c` may set. One list each, read by every git guard:
# block-main-destructive-git.sh (through lib/main-git-guard-history.sh) denies
# setting a command key, inline or persisted, block-no-verify.sh reads
# core.hooksPath through the same classifier, and classify-git-command.sh falls
# through on either and approves only the safe keys. Defines functions and data
# and does no other work at source time.
#
# Why. classify-git-command.sh approves ordinary git calls without a prompt, so
# a key in this list would be an unprompted shell: `git -c 'alias.x=!cmd' x`,
# or `git config core.sshCommand cmd` followed by any fetch. An include pulls in
# a file that can set any of them, so the include keys are listed too.
#
# Matching. Keys are compared lowercased, since git's section and variable names
# are case-insensitive (a subsection is not, but lowercasing only widens the
# match). Each entry is a glob over the whole key.

# shellcheck disable=SC2034  # read by the callers named above
GAIA_GIT_COMMAND_CONFIG_KEYS=(
  'alias.*'
  core.sshcommand core.pager core.editor core.fsmonitor core.askpass
  core.gitproxy core.alternaterefscommand
  sequence.editor
  diff.external 'diff.*.command' 'diff.*.textconv'
  'filter.*.clean' 'filter.*.smudge' 'filter.*.process'
  'merge.*.driver'
  credential.helper 'credential.*.helper'
  gpg.program 'gpg.*.program' gpg.ssh.defaultkeycommand
  'pager.*'
  'difftool.*.cmd' 'mergetool.*.cmd'
  uploadpack.packobjectshook 'remote.*.uploadpack' 'remote.*.receivepack'
  'hook.*.command'
  include.path 'includeif.*.path'
  'browser.*.cmd' 'man.*.cmd'
  interactive.difffilter
)

# The keys classify-git-command.sh approves on an inline `-c`, lowercased and
# matched whole. None names a program; a `-c` of any other key falls through.
GAIA_GIT_SAFE_CONFIG_KEYS=(
  core.quotepath user.name user.email core.filemode commit.gpgsign color.ui
)

# gaia_git_config_key_class <key> [<value>]: print `hookspath` for
# core.hooksPath, `runs-command` for a key in GAIA_GIT_COMMAND_CONFIG_KEYS that this value
# makes run something, and nothing otherwise. A caller that cannot know the
# value (`--config-env` names an environment variable) passes `!`, the value
# that runs a command for every key. Value exemptions:
#   - an alias runs a shell only through a leading `!`, but a plain alias is
#     re-read as git's own options, so one carrying `-c` or `--config-env`
#     reaches every key here too;
#   - `pager.<command>` and core.fsmonitor also take a boolean, which runs
#     nothing (or git's built-in monitor).
gaia_git_config_key_class() {
  local key value="${2-}" pattern
  key=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  if [ "$key" = core.hookspath ]; then
    printf 'hookspath\n'
    return 0
  fi
  for pattern in ${GAIA_GIT_COMMAND_CONFIG_KEYS[@]+"${GAIA_GIT_COMMAND_CONFIG_KEYS[@]}"}; do
    # shellcheck disable=SC2053  # false positive: the unquoted right side is the list's glob
    [[ $key == $pattern ]] || continue
    case "$key" in
      alias.*)
        case "$value" in
          '!'* | -c\ * | *\ -c\ * | --config-env* | *\ --config-env*) ;;
          *) return 0 ;;
        esac
        ;;
      pager.* | core.fsmonitor)
        case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
          true | false | yes | no | on | off | 1 | 0) return 0 ;;
        esac
        ;;
    esac
    printf 'runs-command\n'
    return 0
  done
  return 0
}

# gaia_git_config_section_runs_command <section>: 0 when a key in
# GAIA_GIT_COMMAND_CONFIG_KEYS can live in <section>, so renaming another section to it can create one
# (`git config --rename-section foo alias` turns `foo.x` into an alias).
gaia_git_config_section_runs_command() {
  local section pattern
  section=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  section="${section%%.*}"
  for pattern in ${GAIA_GIT_COMMAND_CONFIG_KEYS[@]+"${GAIA_GIT_COMMAND_CONFIG_KEYS[@]}"}; do
    [ "${pattern%%.*}" = "$section" ] && return 0
  done
  return 1
}
