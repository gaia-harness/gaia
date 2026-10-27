#!/usr/bin/env bash
# SC2016 is intentional file-wide: the awk programs below are single-quoted
# precisely so that `$?`, `$(`, and every awk field reference reach awk as
# literal program text. An expansion the shell performed here would delete the
# detector rather than help it.
# shellcheck disable=SC2016
#
# lint-errexit-status-read.sh: flag every read of `$?` that follows a bare
# command-substitution assignment while errexit is armed. Run it directly from
# the repo root: `bash .gaia/scripts/lint-errexit-status-read.sh`.
#
# Exit 0 when clean, and 1 either with a file:line report on any hit or on a
# scan set that came back empty, which this gate reads as a broken discovery
# rather than a clean tree. The git hooks are the one surface where an empty
# set is a legitimate tree, and they never reach this status: that status is
# tolerated where the hooks are read, for the reason stated there. Four
# statuses say the gate never ran at all: 2 when guard-awk-lib.sh is missing
# beside this script or refuses one of this gate's calls to it, 3 when a
# scan-set discovery failed, 5 when no awk interpreter is present at all, and 6
# when GAIA_AWK resolves to an interpreter that identifies as neither mawk nor
# BWK one-true-awk. Every runner folds any non-zero into its own failure today,
# so the split serves a person reading the output rather than a caller
# branching on it.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-errexit-status-read.bats, which the `Audit CI Tests`
# CI job runs, and folded into .gaia/tests/shell-lint.sh so every shell-lint
# caller enforces the class. Also runnable directly:
# `bats .gaia/scripts/tests/lint-errexit-status-read.bats`.
# gaia:maintainer-only:end
#
# Why: an assignment takes the exit status of its command substitution, so under
# `set -e` a failing command terminates the script ON THE ASSIGNMENT LINE and
# the status read that follows never runs:
#
#     out="$(some_command ...)"
#     rc=$?                       # unreachable
#     if [[ $rc -ne 0 ]]; then    # dead, and so is everything it guards
#
# The observable outcome is a bare non-zero exit carrying none of the
# diagnostics the author wrote, and the branch that was supposed to handle the
# failure is never entered. Two instances of exactly this shape shipped in a
# CI composite action (gaia-react/gaia#1477, gaia-react/gaia#1478); one of
# them silently disabled the whole post-merge revert escalation, because three
# later steps were gated on a step outcome that could no longer be reached, so
# a CI failure that could not be reverted escalated to nobody.
#
# The repair is always the same and never wrong -- move the status out of the
# assignment's way, so the shell has a chance to run the next line:
#
#     rc=0
#     out="$(some_command ...)" || rc=$?
#
# Why a repo-authored gate rather than a linter setting: three oracles were
# measured against the shape and none of them sees it.
#
#   - shellcheck 0.11.0 at severity `style`, the strictest floor
#     .gaia/tests/shell-lint.sh uses, exits 0 on the snippet above. SC2181 fires
#     on `if [ $? -ne 0 ]` after a PLAIN COMMAND and it does still fire on that
#     spelling here, but a capture into a variable draws nothing, and shellcheck
#     does not model `set -e` assignment status at all. The uncovered half is
#     therefore the capture, which is also the form both shipped instances took.
#   - actionlint v1.7 does not lint composite-action step bodies at all.
#   - The `run:` bodies of workflows and composite actions are shell that no
#     `*.sh` glob reaches, so shell-lint's own discovery never opens the file
#     either shipped instance lived in.
#
# Scan surface, and the halves of it that arm differently:
#
#   tracked `*.sh` and the extensionless git hooks -- armed only where the
#     file turns errexit on, tracked line by line so a `set +e` disarms and a
#     later `set -e` re-arms. Off by default is the truthful model here: a
#     script with no `set -e` does not carry the class at all, and
#     legitimate assignment/`rc=$?` pairs in this tree sit in exactly such
#     files. Arming unconditionally would demand a rewrite of every one of
#     them with no defect behind any.
#
#   `.github/workflows/` and the composite actions under `.github/actions/` --
#     `run:` bodies only, armed BY DEFAULT. GitHub Actions runs a step body as
#     `bash -e {0}` (and `bash -eo pipefail {0}` under an explicit
#     `shell: bash`), so errexit is on whether or not the body says so, which is
#     precisely why both shipped instances were live. A `set +e` inside the body
#     still disarms from that point.
#
#   tracked `*.bats` -- its own arm, armed BY DEFAULT, because bats runs every
#     test body under errexit while a suite file carries no `set -e` of its own.
#     Folding it into the `*.sh` set above, which is off by default, is what made
#     the whole surface read clean by construction rather than by measurement.
#
#     A suite is also where this class is DEMONSTRATED, so the line the gate
#     reads may be a fixture the test writes rather than shell the test runs.
#     Telling those apart is not this file's job: the shared
#     .gaia/scripts/guard-awk-lib.sh owns the argument-region rule, the
#     suppression pragma, and the invocation census, and every gate that
#     scans suites reads the same answers from it. The convention and the
#     reasoning behind it live in
#     wiki/decisions/Shell Guard Fixture Discrimination.md.
#
#     One arming rule is this gate's own rather than the library's. A helper
#     function defined in a suite whose EVERY invocation in that file is
#     `run <name>` is NOT armed, because bats disables errexit under `run`, so
#     the assignment hands its status to `run` and the read below it is live.
#     The library answers the census question; the exemption below is what turns
#     the answer into a verdict. Everything else stays armed: a body inside a
#     `@test`, a helper with at least one plain call site, and a helper with NO
#     call site at all in the file, that last one because an uninvoked helper is
#     evidence of nothing and fails closed.
#
#     The library's suppression pragma is honored on this surface and on no
#     other. A pragma naming this gate anywhere else it scans is reported as
#     waiving nothing, on the line it targets, whether or not that line carries
#     an instance -- reading it only where a hit fires would make the finding
#     silently inert over every pragma above a clean line, which is most of them.
#     Malformed pragmas, an unresolvable guard token or a missing reason, are the
#     sibling lint-git-path-quoting.sh's to report, so a malformed one is named
#     once rather than once per gate. One surface is left unowned by that
#     arrangement rather than covered by it: that gate does not scan the
#     composite actions under .github/actions/, which this gate and the other
#     siblings reach through the shared `workflows` set, so a malformed pragma
#     written in one is reported nowhere. This gate reports only the UNUSED
#     pragma that names it.
#
# One file type is deliberately out of the surface:
#
#   *.md    -- the sibling path-quoting gate scans the fenced blocks of tracked
#              markdown because several are executed instruction. The same
#              fixture problem applies with more force here: this file's own
#              class documentation, and the wiki page describing the gate, both
#              have to SHOW the broken shape to explain it.
#
# What is deliberately NOT claimed, each because the status the read sees comes
# from somewhere other than the substitution:
#
#   - A PREFIXED assignment (`local out=$(cmd)`, and the same for `declare`,
#     `readonly`, `typeset`, and `export`). There the exit status belongs to the
#     builtin rather than to the substitution, so errexit does not fire and the
#     read is reachable -- it just always reads zero. That is a real defect and a
#     different one, and shellcheck already carries it as SC2155.
#   - An assignment whose status an AND-OR list CONSUMES rather than lets fall
#     to the shell: `out=$(cmd) || rc=$?`, and the same in a pipeline. That is
#     exactly what the repair above builds, so flagging it would red the tree on
#     the fix. The exemption is positional and this bullet claims only the
#     position it covers: errexit spares the NON-FINAL commands of an AND-OR
#     list, so a trailing `cond && out=$(cmd)` does exit, and that shape is a
#     blind spot below rather than a semantic non-issue.
#   - An ENV-PREFIX assignment (`FOO=$(cmd) run_thing`). The status belongs to
#     the prefixed command, so a failing substitution in the prefix never trips
#     errexit; `set -e; FOO=$(false) echo hi` runs and survives.
#   - An assignment used as an `if`/`while`/`until` CONDITION, which never
#     matches the assignment shape below because the line begins with the
#     keyword.
#
# Known FAIL-OPEN blind spots, stated rather than discovered later:
#   - A HEREDOC BODY is swallowed as data on every surface, so an instance
#     written inside one is never reported. That is the deliberate reading a
#     body is data the shell hands to a command rather than shell it runs, and
#     it is stated here as the fail-open it also is.
#   - The `run`-only exemption above is file-scoped, because the census that
#     feeds it reads one file. A helper called `run <name>` throughout its own
#     suite and called plainly from a `setup_suite` or a sourced helper file is
#     disarmed here on evidence that does not cover where it actually runs.
#   - A helper invoked only from inside a string (`bash -c "helper"`) is not
#     counted as invoked at all, so a helper otherwise reached only through `run`
#     keeps its exemption.
#   - An assignment in the FINAL position of an AND-OR list (`cond && out=$(cmd)`
#     with a status read below it). The shell does exit there, so it is the
#     class, and it is missed because a control operator anywhere in the
#     statement disqualifies it with no position tracking. Widening this needs
#     the walk to know which side of the operator the assignment sits on, which
#     is real parsing rather than a looser test, and no tracked file here writes
#     the shape.
#   - A statement whose first word ends on a LATER line than the one the
#     assignment starts on. The env-prefix exclusion reads the first top-level
#     whitespace as an offset into a single line, so a continued statement is
#     classified as a bare assignment.
#   - A `$?` reached through a variable indirection, or a status stored by a
#     `trap` body that a later line then reads. Both are genuinely deferred
#     reads whose value depends on when the body runs, which a line-oriented
#     scan cannot resolve.
#   - More than one heredoc opened on a single line (`cat <<A <<B`): only the
#     last delimiter is recorded, which swallows every body through its terminator
#     as data, so only a body line equal to that last delimiter ends the swallow
#     early.
#   - A `<<` inside a bare `(( ))` arithmetic command, as opposed to the `$(( ))`
#     expansion the walk does track, is read as a heredoc redirection. No tracked
#     file here uses the bare form.
#   - A step whose `shell:` is not bash (`python`, `pwsh`). Its body is armed as
#     bash would be, but the shape below is bash syntax that such a body does not
#     carry, so the arming costs nothing.
#   - A `run:` written as a multi-line plain or quoted flow scalar rather than a
#     block scalar; only its first line is read, the same bound the sibling
#     run-interpolation gate carries and for the same reason.
#   - An ANSI-C literal whose OPENER is split by a backslash continuation, the
#     `$` last on one line and the quote first on the next, is read as an
#     ordinary single quote. guard-awk-lib.sh states the same bound and declines
#     the same shape, deliberately: two tokenizers disagreeing about what one
#     sequence of bytes means is worse than a bound both of them hold. It does
#     not fail silently either way, since the misread quote leaves state open and
#     the desync verdict below fires.
#   - The ANSI-C frame is walk()'s. has_status_read() and eat_word() still read
#     `$\047...\047` as an ordinary single-quoted span, so an escaped quote
#     inside one flips their line-local quote state and a literal `$?` behind it
#     can read as a status read (a false positive) or a word boundary can be
#     misplaced in the env-prefix scan. Both are bounded to the single line each
#     one is handed, because neither carries state across lines, which is why
#     the repair went to the walk that does.
#
# Known FALSE POSITIVES, a third direction and the one worth naming explicitly
# because each costs a correct line a wrong verdict. None occurs in this tree.
# The group that used to dominate this list, a single-token exclusion stopping at
# the first prefix word, is closed: the exclusion below consumes the whole
# prefix, assignments and redirections alike, in any order, and applies itself to
# the command word behind it. Two further mechanisms close the rest of it: a
# redirection operand that is a nested command is followed as a REGION rather
# than broken on (eat_word() and walk() below), and the walk COUNTS top-level
# substitutions, so a statement whose status a second one supplies is not
# attributed to the first, which is the one this gate flags (W_substitution_count below).
#
# What is left is one UNDECIDABLE FAMILY rather than a list of unimplemented
# shapes, and it is undecidable in both directions at once:
#
#   - An assignment-only statement running TWO OR MORE substitutions. The shell
#     takes the status of the last one, so whether the read below is dead
#     depends on whether that last substitution fails, which is a runtime fact
#     no static reader has. The gate is quiet on the whole family, so it misses
#     the failing case (`out=$(false) FOO=$(false)` exits, and is the class).
#     Four spellings reach it and are ONE shape rather than four, because a word
#     boundary is not a distinction the shell draws here: a later prefix word
#     (`out=$(a) FOO=$(b)`), a redirection operand (`out=$(a) > "$(b)"`),
#     concatenation inside one value (`out="$(a)$(b)"`), and two adjacent quoted
#     words (`out="$(a)""$(b)"`). A substitution inside a `${...}` expansion
#     counts too, since the walk does not track `${`.
#     Quiet is chosen because the gate`s printed message names the flagged
#     substitution as the one whose failure exits, and with a later substitution
#     present that sentence is false: it names the wrong command and prints a
#     repair built around it, the direction that gets a gate bypassed rather
#     than obeyed. Reporting a single substitution is a decision under the same
#     uncertainty and is not a stronger claim, only one whose message is true.
#     Two kinds of substitution deliberately do NOT count toward the two,
#     because neither can be the last one the statement ran: a NESTED one
#     (`out=$(a $(b))`), and one inside a process-substitution operand
#     (`out=$(a) > >(echo "$(b)")`), which runs in an async subshell.
#
# Not a false positive, and here because it reads like one, a MODELLING DECISION
# that has been settled rather than left open:
#
#   - An INPUT redirection on an assignment-only statement (`out=$(cmd) < log`),
#     which is the one shape whose ground truth depends on the interpreter. Under
#     bash 3.2 the statement takes the substitution status and exits, so the read
#     below it is unreachable. Under bash 5 the status is reset to zero and the
#     read runs, ALWAYS READING ZERO while the command failed and the variable is
#     empty, so the failure is swallowed silently instead. Those are the same
#     defect approached from opposite sides, and the repair this gate prints
#     (`rc=0; out="$(cmd)" || rc=$?`) is correct under both, so the gate reports
#     under both and needs no version to target. An OUTPUT redirection in the
#     same position exits on either version, so only the input direction diverges
#     and only where no command word follows.
#
# This list is kept honest by measurement rather than by memory. The sibling bats
# suite carries a differential test that runs a matrix of prefix shapes under a
# real shell and requires the gate to agree with what the shell did, so a shape
# stops being a bound when it is fixed rather than when someone remembers to edit
# this comment. Enumerating shapes by hand is what put four defects on the old
# exclusion across four review rounds, the last of them a silent fail-open.
#
# The matrix has a limit worth stating beside the list it verifies: it asserts
# AGREEMENT with the shell on rows it is given, so it reds when a listed row
# regresses and can never surface an UNLISTED false positive. Both entries above
# are also outside what it can measure, for two different reasons. The
# undecidable family has no single shell answer to agree with, since each
# spelling reaches or exits by the runtime status of its last substitution, so a
# row would pin whichever instance was written. The input-redirection decision
# has no version-independent one, so a row would record whichever interpreter
# the probe resolved as the contract. Its template also hardcodes a space before
# the suffix, so the same-word spellings cannot be expressed as rows at all.
# Named tests in the suite pin both, and this list is still maintained by hand.
#
# None of those can leave the tokenizer silently out of sync. Tokenizer state is carried across lines, so any
# bound that loses sync leaves a quote, a substitution, or a heredoc open at the
# end of the region, and `check_desync` below reports the region as one this gate
# cannot certify rather than printing `clean` over lines it never read. That
# matters more than the bounds themselves: a line-oriented scan that desyncs
# swallows the REST OF THE FILE, not the rest of the statement, so the quiet
# failure is total rather than local.

set -euo pipefail

# The shared fixture-versus-execution discriminator, resolved SCRIPT-relative
# because every fixture test in the sibling suite runs this gate with cwd inside
# a throwaway repo that carries no .gaia/scripts of its own, so a cwd-relative
# load would abort the gate on every one of them.
#
# The `set +e; ...; set -e` bracket is not decoration. This file arms errexit on
# the line above, and an unbracketed load in an errexit-reachable file would
# abort the script outright if the library were ever present but unparseable.
# The `if` on the second line is load bearing for the same reason: under
# errexit a bare `[ ... ] && ...` whose test is false returns 1 and kills the
# script.
_gaia_guard_library_directory="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_library_directory" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_library_directory="."; fi
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
set +e; [ -f "$_gaia_guard_library_directory/guard-awk-lib.sh" ] && . "$_gaia_guard_library_directory/guard-awk-lib.sh" 2>/dev/null; set -e
type gaia_guard_bats_files >/dev/null 2>&1 || {
  printf 'lint-errexit-status-read: guard-awk-lib.sh is missing beside this script\n' >&2
  exit 2
}
case "$GAIA_AWK_STATUS" in
  5)
    printf 'lint-errexit-status-read: no awk interpreter found; install mawk (macOS: brew install mawk; Debian/Ubuntu: apt-get install mawk) or ensure /usr/bin/awk is present\n' >&2
    exit 5
    ;;
  6)
    printf 'lint-errexit-status-read: GAIA_AWK resolved to an unsanctioned interpreter (%s); the sanctioned set is mawk and BWK one-true-awk\n' "$GAIA_AWK_IDENTITY" >&2
    exit 6
    ;;
esac

# Shared detector, concatenated into both scan programs below so the matcher is
# written once and the two surfaces cannot drift apart. Single-quoted, and every
# literal quote inside is spelled as an escape (`\047` for `'`), so the shell
# passes the program through untouched.
# The detector lives in two pieces beside this script, loaded under the same
# bracket as the guard library above and joined back into the one program.
# shellcheck source=.gaia/scripts/lint-errexit-status-read-walk.sh
set +e; [ -f "$_gaia_guard_library_directory/lint-errexit-status-read-walk.sh" ] && . "$_gaia_guard_library_directory/lint-errexit-status-read-walk.sh" 2>/dev/null; set -e
# shellcheck source=.gaia/scripts/lint-errexit-status-read-detect.sh
set +e; [ -f "$_gaia_guard_library_directory/lint-errexit-status-read-detect.sh" ] && . "$_gaia_guard_library_directory/lint-errexit-status-read-detect.sh" 2>/dev/null; set -e
if [ -z "${CORE_AWK_WALKER:-}" ] || [ -z "${CORE_AWK_DETECTOR:-}" ]; then
  printf 'lint-errexit-status-read: lint-errexit-status-read-walk.sh or lint-errexit-status-read-detect.sh is missing beside this script\n' >&2
  exit 2
fi
readonly CORE_AWK="$CORE_AWK_WALKER$CORE_AWK_DETECTOR"

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

# The scan surface comes from the shared library rather than from a read loop
# here, so every gate consuming it discovers the same set the same way and a
# widened pathspec cannot reach one of them and miss the others. The call fills
# GAIA_GUARD_SCAN_FILES and returns non-zero on an empty surface, which is a
# hard error rather than a clean tree; the status is read directly, because a
# substitution would swallow it.
# Each set is copied out of the library's one global before the next call
# overwrites it, because this gate arms the three differently below.
gaia_guard_scan_files lint-errexit-status-read shell || exit $?
sh_files=(${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"})

# The git hooks are read as their own set because the `*.sh` glob misses
# extensionless files. Git execs a hook directly and the hook arms itself with its
# own `set -e`, so they are armed the same way as `*.sh`: off until the file turns
# errexit on.
#
# Alone among the sets this gate reads, an empty one is a legitimate tree rather
# than a broken discovery: a repository can carry no tracked hook at all, and the
# call above already proved `git ls-files` answers here. So the library's
# empty-surface status is tolerated, and its message, which would be wrong in
# that case, is dropped rather than surfaced as this gate's own error.
#
# That status and no other. Every other one the library returns says the call is
# wrong or the discovery broke, and swallowing one here would leave this gate,
# the only one reading the hooks, scanning no hook while printing `clean`.
#
# So the library's message is held rather than discarded, and replayed on every
# status but the tolerated one. Discarding it outright would cost the operator
# the only text that separates the causes sharing a status: status 3 is returned
# for a failed discovery, a failed sort, and a scratch file that could not be
# created, and the line held here is what names which.
githook_files=()
githook_error_file="$(mktemp -t gaia-errexit-githooks-XXXXXX)"
if gaia_guard_scan_files lint-errexit-status-read githooks 2>"$githook_error_file"; then
  githook_files=(${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"})
else
  githook_status=$?
  if [ "$githook_status" -ne 1 ]; then
    cat "$githook_error_file" >&2
    rm -f "$githook_error_file"
    exit "$githook_status"
  fi
fi
rm -f "$githook_error_file"

gaia_guard_scan_files lint-errexit-status-read workflows || exit $?
yaml_files=(${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"})

# The bats set comes from the same library, and for the same reason: a change to
# that discovery cannot reach one consuming gate and miss the others.
#
# Deliberately its own call rather than a set folded into the ones above: an
# operator whose discovery broke needs to know WHICH surface came back empty,
# and each call's message names only the sets that call asked for.
gaia_guard_bats_files lint-errexit-status-read || exit 1

report=""
for scanned_file in ${sh_files[@]+"${sh_files[@]}"}; do
  [ -f "$scanned_file" ] || continue
  hits="$("$GAIA_AWK" -v file="$scanned_file" -v armed_init=0 -v is_bats=0 -v scripts_directory="$_gaia_guard_library_directory" \
    "$GAIA_GUARD_AWK$CORE_AWK$SHELL_AWK" "$scanned_file")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done
# The githooks set is allowed to be empty and is simply skipped, mirroring the way
# .gaia/tests/shell-lint.sh treats its own *.bats set: an adopter clone may
# legitimately carry no hooks, while every real tree carries tracked *.sh, which
# is why only that set and the workflows are hard preconditions above.
for scanned_file in ${githook_files[@]+"${githook_files[@]}"}; do
  [ -f "$scanned_file" ] || continue
  hits="$("$GAIA_AWK" -v file="$scanned_file" -v armed_init=0 -v is_bats=0 -v scripts_directory="$_gaia_guard_library_directory" \
    "$GAIA_GUARD_AWK$CORE_AWK$SHELL_AWK" "$scanned_file")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done
for scanned_file in ${yaml_files[@]+"${yaml_files[@]}"}; do
  [ -f "$scanned_file" ] || continue
  hits="$("$GAIA_AWK" -v file="$scanned_file" -v armed_init=1 -v is_bats=0 -v scripts_directory="$_gaia_guard_library_directory" \
    "$GAIA_GUARD_AWK$CORE_AWK$YAML_AWK" "$scanned_file")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done

# The bats set, armed ON and named TWICE: the first pass accumulates the fixture
# constants a forward-only scan cannot classify, the second one classifies.
for scanned_file in ${GAIA_GUARD_BATS_FILES[@]+"${GAIA_GUARD_BATS_FILES[@]}"}; do
  [ -f "$scanned_file" ] || continue
  hits="$("$GAIA_AWK" -v file="$scanned_file" -v armed_init=1 -v is_bats=1 -v scripts_directory="$_gaia_guard_library_directory" \
    "$GAIA_GUARD_AWK$CORE_AWK$BATS_AWK" "$scanned_file" "$scanned_file")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  # The repair hint answers a status-read finding. A desync ERROR is a different
  # verdict with a different (and unknown) repair, so printing the hint under a
  # report carrying only those would name a fix the operator does not need.
  # ONE awk pass, not a quiet grep downstream of a pipe. A quiet grep exits at
  # its first match and closes the pipe; the upstream takes SIGPIPE and returns
  # 141, and `pipefail` promotes that to the pipeline's status, so the test
  # would answer FALSE on a report that does carry a status-read finding.
  # .gaia/scripts/lint-sigpipe-readers.sh is the gate that keeps the shape out.
  #
  # `length($0) > 0` is what makes this equivalent to the pipeline it replaced
  # rather than to a here-string of it. `<<<` appends a newline, and $report
  # already ends with one, so the here-string carries a trailing EMPTY line that
  # an inverted match would count as a non-matching line and succeed on
  # unconditionally. Only a zero-length line is dropped: a whitespace-only line
  # counted as non-matching before and still does.
  if "$GAIA_AWK" '
      length($0) > 0 && $0 !~ /: ERROR: the scan lost track of shell state/ { found = 1 }
      END { exit(found ? 0 : 1) }
    ' <<<"$report"; then
    # printf, not echo: the hint carries `$` and backslashes that echo may expand
    # depending on the shell (SC2028). The format string is single-quoted so the
    # sample code inside stays literal -- it is being printed, not run.
    # shellcheck disable=SC2016
    printf 'Fix each by letting the assignment hand its status on instead of dying on it:\n    rc=0\n    out="$(some_command ...)" || rc=$?\n' >&2
  fi
  exit 1
fi

echo "lint-errexit-status-read: clean" >&2
exit 0
