#!/usr/bin/env bash
# SC2016 is intentional file-wide, for the reason lint-errexit-status-read.sh
# gives: the awk programs below reach awk as literal program text. SC2034
# too: the strings it assigns are read by that script, never here.
# shellcheck disable=SC2016,SC2034
#
# The per-surface scan programs of lint-errexit-status-read.sh, one per arm,
# each appended to that script's CORE_AWK at call time. Sourced only by that
# script; assigns those strings and does no other work at source time.

# scan_shell: the *.sh and git hooks half. Errexit starts OFF, because a script that
# never turns it on does not carry the class.
readonly SHELL_AWK='
BEGIN { armed = armed_init; gaia_scan_reset(); reset_state() }
{ gaia_scan_feed($0, is_bats); pragma_offsurface(FNR); feed($0, FNR) }
END { check_desync("the file") }
'

# scan_yaml: the workflow / composite-action half. The `run:` body is
# located structurally rather than by scanning the whole file, because the shape
# is only shell inside a body; the surrounding YAML is not shell at all. The
# locator is the one the sibling lint-workflow-run-interpolation.sh uses, for
# the same reasons its comments give. Errexit starts ON for every body, per
# `bash -e {0}`.
readonly YAML_AWK='
# yaml_feed: the run:-body feed point. The call sites below reach it, so the
# discriminator hand-off lives here rather than being repeated at each of them
# and forgotten at the next one somebody adds.
function yaml_feed(line, line_number) {
  gaia_scan_feed(line, is_bats)
  pragma_offsurface(line_number)
  feed(line, line_number)
}
BEGIN { inrun = 0 }
{
  if (inrun) {
    # A blank line belongs to the block scalar rather than ending it.
    if ($0 ~ /^[[:space:]]*$/) { yaml_feed($0, FNR); next }
    column = match($0, /[^ ]/)
    if (column > run_column) { yaml_feed($0, FNR); next }
    inrun = 0
    # The body just ended, so this is where its state has to balance. A `run:`
    # body is its own script and the state resets on entry, which means an
    # unclosed region in one body cannot be inherited from the last, and neither
    # can it be certified.
    check_desync("a run: body")
    # Fall through: this same line may itself be the next `run:` key.
  }
  if ($0 ~ /^[[:space:]]*(-[[:space:]]+)?run:/) {
    run_column = index($0, "run:")
    value = substr($0, run_column + 4)
    # A block scalar header carries nothing but the indicator, its optional
    # chomping and indentation digits in either order, and an optional comment.
    # Anything else on the line is inline content, which is a single command and
    # so cannot carry a two-line shape.
    if (value ~ /^[[:space:]]*[|>][-+0-9]*[[:space:]]*(#.*)?$/) {
      inrun = 1
      armed = 1
      gaia_scan_reset()
      reset_state()
    } else {
      inrun = 0
    }
  }
}
END { if (inrun) check_desync("the last run: body") }
'

# scan_bats: the `*.bats` half, and its OWN arm rather than a fold into the
# `*.sh` set. Errexit starts ON for every tracked suite, because bats runs each
# test body under it whether or not the file ever says `set -e`; folded into the
# off-by-default script arm the whole surface reads clean by construction, which
# is what it did.
#
# Two passes, the file named twice on the command line. A fixture constant is
# bound far above the helper call that consumes it, so a forward-only scan
# cannot tell the literal from executed shell; the first pass accumulates and
# the second classifies. gaia_scan_feed comes first and ahead of any `next`,
# because the pragma reader behind it has to see the comment lines feed() itself
# returns on.
readonly BATS_AWK='
BEGIN { armed = armed_init; gaia_scan_reset(); reset_state() }
is_bats && NR == FNR { gaia_scan_prepass($0); next }
{ gaia_scan_feed($0, is_bats); feed($0, FNR) }
END {
  check_desync("the file")
  gaia_scan_end(file, is_bats, "lint-errexit-status-read", 0, 0)
}
'
