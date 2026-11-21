#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # the deny reasons are read by the sourcing guard
#
# The gate-input path classes of block-audit-loop-write.sh: the protected
# folder (the audit loop state, the checkpoint override and every other
# occupant) and the per-session context readings. Holds their deny reasons and
# their path predicates. One library holds both classes because guarded_class
# reads both spellings in one pass. Sourced by that guard; it is not a hook and
# carries no registration.
#
# Bash 3.2 compatible.

DENY_STATE_MESSAGE="BLOCKED: block-audit-loop-write.sh: the audit loop state (<main>/.gaia/local/protected/audit-loop/) is written only by the audit loop hooks. Claude never writes, edits, moves or deletes it. A human answers a checkpoint through the pinned AskUserQuestion, or by typing a whole prompt that is exactly the audit-grant <n> or audit-accept line (see wiki/concepts/PR Merge Workflow.md, #### The branch checkpoint). A corrupt state file is repaired by a human from a terminal outside Claude Code."
DENY_CONTEXT_MESSAGE="BLOCKED: block-audit-loop-write.sh: the context readings (<main>/.gaia/local/cache/shared/context/) are written by the statusline on each render, and the audit checkpoint trusts them. Claude never writes, edits, moves or deletes them. A human answers a checkpoint through the pinned AskUserQuestion, or by typing a whole prompt that is exactly the audit-grant <n> or audit-accept line (see wiki/concepts/PR Merge Workflow.md, #### The branch checkpoint)."
DENY_OVERRIDE_MESSAGE="BLOCKED: block-audit-loop-write.sh: <main>/.gaia/local/protected/checkpoint-override.json is the per-machine audit checkpoint override, and only a human edits the override, by hand from outside Claude Code. Claude never creates, writes, edits, moves or deletes it. GAIA's writable per-machine opt-ins live in <main>/.gaia/local/settings.json, which this guard does not cover. A human answers a checkpoint through the pinned AskUserQuestion, or by typing a whole prompt that is exactly the audit-grant <n> or audit-accept line (see wiki/concepts/PR Merge Workflow.md, #### The branch checkpoint)."
DENY_FOLDER_MESSAGE="BLOCKED: block-audit-loop-write.sh: <main>/.gaia/local/protected/ holds state the audit checkpoint trusts, and only hooks or a human write <main>/.gaia/local/protected/, by hand from a terminal outside Claude Code. Claude never creates, writes, edits, moves or deletes anything in it. A human answers a checkpoint through the pinned AskUserQuestion, or by typing a whole prompt that is exactly the audit-grant <n> or audit-accept line (see wiki/concepts/PR Merge Workflow.md, #### The branch checkpoint)."

# protected_class <path> <folder>: print the class a path inside, or equal to,
# the protected folder names. The audit loop state directory and the exact
# override file name get their own message; every other occupant, a sibling
# such as `protected/checkpoint-override.json.bak` included, is the folder.
protected_class() {
  case "$1" in
    "$2/audit-loop" | "$2/audit-loop"/*) printf state ;;
    "$2/checkpoint-override.json") printf override ;;
    *) printf folder ;;
  esac
}

# guarded_class <path>: print the guarded class a path spelling names, or
# nothing. The protected arm pairs the folder itself with its children, so a
# sibling beside it such as `.gaia/local/protected-notes.md` and the writable
# opt-ins file `.gaia/local/settings.json` do not match.
guarded_class() {
  case "$1" in
    */.gaia/local/protected/* | */.gaia/local/protected) protected_class "$1" "${1%%/.gaia/local/protected*}/.gaia/local/protected" ;;
    */.gaia/local/cache/shared/context/* | */.gaia/local/cache/shared/context) printf context ;;
  esac
}
