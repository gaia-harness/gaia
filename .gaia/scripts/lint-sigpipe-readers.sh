#!/usr/bin/env bash
# SC2016 is intentional file-wide: every awk program below is single-quoted
# precisely so every `$` and awk field reference reaches awk as literal program
# text rather than being expanded by this shell first.
# shellcheck disable=SC2016
#
# lint-sigpipe-readers.sh: flag a short-circuiting reader -- `grep` or `rg` told
# to stop early, whether by a `-q`-bearing flag cluster, `--quiet`, `--silent`,
# or a match count (`-m`, `--max-count`) -- standing downstream of a `|` where
# `pipefail` is armed: in a tracked shell script, and in an Actions `run:` body,
# which is shell by another name. Run it directly from the repo root:
# `bash .gaia/scripts/lint-sigpipe-readers.sh`.
#
# Exit 0 when clean, and 1 either with a file:line report on any hit or on a
# scan surface that came back empty. Five statuses say the gate never produced
# a verdict at all: 2 when it could not start (guard-awk-lib.sh missing beside
# this script, or no scratch directory), 3 when the scan-surface discovery
# failed, 4 when a workflow carries a `defaults:` key, the one construct the
# shell oracle below refuses to resolve rather than answer wrongly about, 5
# when no awk interpreter is present at all, and 6 when GAIA_AWK resolves to
# an interpreter that identifies as neither mawk nor BWK one-true-awk.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-sigpipe-readers.bats, which the `Audit CI Tests`
# scripts shard runs, and folded into .gaia/tests/shell-lint.sh. Its arming
# takes MORE than that gate's `**/*.sh` paths-filter entry, which reaches only
# half of what this gate reads: the workflow and composite-action entries
# beside it are what arm the other half, and each names this guard. A pull request touching only a workflow that skipped this gate would
# green it having read the very file it changed zero times. Also runnable
# directly: `bats .gaia/scripts/tests/lint-sigpipe-readers.bats`.
# gaia:maintainer-only:end
#
# Why: a short-circuiting reader INVERTS the truth value of the pipeline it
# terminates. `grep -q` exits at its first match and closes the read end of the
# pipe. When the upstream has written more than the pipe buffer (~64KB) and the
# match lands early, the upstream takes SIGPIPE and exits 141; `set -o pipefail`
# promotes that to the pipeline's status, so an `if` or an `&&` reading it takes
# the FALSE branch BECAUSE a match was found. Nothing surfaces it: the pipeline
# is well-formed, both commands did what they were asked, and the wrong branch
# looks exactly like the right one.
#
# Whether a given upstream can outrun the buffer is a data-flow property no
# static check can decide, so this gate does not try. It flags the SHAPE, with
# no discrimination, and that is affordable because the remedy is unconditional
# and free: each repair removes the pipeline outright rather than making the
# race safer, so the class cannot recur on the repaired line. A printf or echo
# feeding the reader becomes a here-string; a command feeding it is captured
# into a variable first; a filter feeding it folds into a single awk pass.
#
# That is the same trade .gaia/scripts/lint-hook-array-guard.sh already makes
# for a class it likewise cannot fully discriminate: a flagged site the author
# believes is genuinely safe takes the fix anyway, so the gate stays
# zero-exception rather than carrying an inline suppression. There is
# deliberately NO pragma.
#
# One trap in the repair itself, because `<<<` appends a newline. That is
# byte-identical to a `printf` of the same value with a trailing newline and
# harmless for an ordinary pattern, but an INVERTED reader (`grep -qv`) reads
# the extra trailing blank line as a non-matching line and then succeeds
# unconditionally. Trim the newline off the value, or fold the whole pipeline
# into one awk pass.
#
# Provenance: four known occurrences before this gate existed, three of them in
# guard machinery, where the failure mode is a guard reporting clean over a live
# defect. gaia-react/gaia#745 (an audit-success check, fixed by
# gaia-react/gaia#748), gaia-react/gaia#757 and gaia-react/gaia#761 (two shapes
# in `audit-noop-detect.sh`), and a hook-classification guard whose first draft
# classified with a filtering grep feeding a quiet one and reported clean over
# the very defect it was written for, on its first run against the live tree.
# Each of the first three was patched in place with no gate left behind, which
# is why the fourth had nothing to catch it. gaia-react/gaia#1810 is the issue
# that replaced the patches with this tree-wide gate.
#
# Nothing else in the tree reaches the class. shellcheck at the `*.sh` severity
# floor .gaia/tests/shell-lint.sh sets returns exit 0 on a fixture carrying both
# shapes, and the `code-audit-maintainer-shell` agent has caught it once but is
# model-dispatched and advisory, so nothing enforced it.
#
# ---------------------------------------------------------------------------
# WHICH FILES RUN UNDER PIPEFAIL, which is a closure and not a per-file test
# ---------------------------------------------------------------------------
#
# `pipefail` is a shell OPTION, not a file attribute: it belongs to the process,
# and a sourced library therefore runs under whatever its caller armed. A gate
# that asked only whether the scanned file carries its own `set -o pipefail`
# would report every library clean, and `.claude/hooks/lib/` is exactly where
# three of the four historical occurrences above lived. That is an arming-stage
# hole in the sense .claude/rules/guards-must-fail.md names: correct wherever it
# runs, and never run on the surface that most needs it.
#
# So a file counts as running under pipefail when it arms pipefail itself, OR
# when it is reachable by `source` from a file that does. The seeds are the
# self-arming files; the edges are the `.`/`source` loads; the closure is
# transitive, because a library sourced by a library sourced by an armed entry
# point runs armed too.
#
# "Arms pipefail itself" means at command-substitution depth ZERO, the same test
# the workflow arm applies to a `run:` body and for the same reason: a
# `changed=$(set -o pipefail; ...)` arms its own subshell and nothing outside
# it, so a file whose only arming is that idiom is not a seed. The two arms
# share one arming test rather than two that agree by inspection
# (`arms_at_depth_zero` in lint-sigpipe-readers-detect.sh). What that costs is
# stated below, with the workflow arm's depth test.
#
# An edge resolves by BASENAME against the tracked set, because a load names its
# target through a variable far more often than not
# (`. "$library_directory/guard-awk-lib.sh"`), and no static reader can resolve that
# variable. Two consequences, both stated rather than hidden. A basename shared
# by two tracked files draws an edge to both, so one armed caller can mark a
# same-named file it never loads: that direction costs a correct edit and never
# a missed defect, which is the direction a guard may be wrong in. And a load
# whose target is built entirely from variables, with no literal `*.sh` token on
# the line, draws no edge at all; a file reachable only that way is not covered.
#
# ---------------------------------------------------------------------------
# Scan surface
# ---------------------------------------------------------------------------
#
# Two sets the shared library defines, read as two arms because they decide
# arming differently: tracked `*.sh` (`shell`), and the Actions workflows
# and composite actions (`workflows`). Two surfaces are deliberately outside
# both:
#
#   *.bats            bats-core arms no pipefail by DEFAULT, so an ordinary
#                     suite does not run the class. A suite that arms pipefail
#                     itself does, and that is out of scope by choice rather
#                     than by impossibility: the suites doing it today arm it
#                     inside a command substitution or a `bash -c` fixture,
#                     where the shape is the fixture rather than the suite.
#   the git hooks     `.githooks/*` are POSIX `sh` scripts, which arm no
#                     pipefail either.
#
# What this gate does NOT try to decide: whether the pipeline's status is read
# as a truth value at all. A status nobody reads makes the shape harmless rather
# than absent, and separating the two needs the surrounding control flow. The
# remedy costs the same either way, so the shape is reported wherever it stands.
#
# ---------------------------------------------------------------------------
# THE WORKFLOW ARM, whose arming is a shell oracle rather than a text test
# ---------------------------------------------------------------------------
#
# A `run:` body is shell by another name, and it carries this class exactly as a
# script does. What it does NOT carry is the script arm's arming signal: a body
# inherits pipefail from the step's RESOLVED SHELL rather than from any text in
# it. GitHub's default `run:` shell is `bash -e`, which arms no pipefail; an
# explicit `shell: bash` resolves to `bash --noprofile --norc -eo pipefail`,
# which does. So the body-text test alone would grade every block by whether its
# author happened to write a redundant `set -o pipefail`.
#
# A block is therefore armed when EITHER holds, and the two are independent:
#
#   the resolved shell   the step's own `shell:` value is `bash`, or is a custom
#                        invocation naming `pipefail`. Anything else, including
#                        the absent case that covers every workflow-file step in
#                        this tree, is the bare `bash -e` default and arms
#                        nothing. `shell:` is read at the STEP's own key column,
#                        so the `shell:` that names a dorny/paths-filter filter
#                        inside a `filters: |` block scalar is not mistaken for
#                        one (.github/workflows/shell-lint.yml has two).
#   the body text        the block's own `set -o pipefail`, in the spellings the
#                        script arm already reads. A body that arms pipefail is
#                        armed whatever its shell resolves to.
#
# The substitution-scoped form `changed=$(set -o pipefail; ...)` must NOT arm
# the block around it, and the distinction is not academic: it is the shape this
# tree writes, and reading it as block-level arming would report every one of
# those blocks. So the body-text test fires only at command-substitution depth
# zero, tracked by counting `$(` against `)` across the block and clamped at
# zero. A miscount can go either way, and the two ways are not equally safe. A
# stray `)` (a `case` pattern, an arithmetic `))`) pushes the depth DOWN, which
# reads a substitution-scoped `set` as block-level and reports a block that was
# not armed: that direction costs a correct edit, and the clamp keeps it from
# going below zero. A `$(` that is data rather than code pushes the depth UP,
# which reads a real arming as scoped and reports nothing: that is the missed
# defect this gate exists to prevent, and the carry below is built against it.
#
# The depth a line hands the next one is the LOWER of two counts over that
# line, both walked from the same carried-in depth: the raw line, and a copy
# with each single-quoted span removed, from one quote to the next, where an
# unterminated quote stays with everything after it. Single quotes are the
# tractable case because shell allows no escape inside them, so a literal `$(`
# in a single-quoted `grep -F` pattern drops out while a live `$(` inside double
# quotes stays. The stripped count alone is not safe: a strip cannot tell a
# quote that opens a span from an apostrophe inside a double-quoted string, so
# `x=$(echo "it's"); y='z'` strips to an unbalanced `$(` on a line whose raw
# count is balanced, and a stripped-only carry would read the next arming as
# scoped. The minimum cannot rise above the raw count: the depth walk is
# monotone in the depth it starts from, so from zero, by induction, every line
# ends at or below where the raw count would end it, and the strip can remove a
# false negative but never add one. The same misalignment can pull the carry
# BELOW the true depth, when an apostrophe inside a double-quoted word pairs
# across a real open `$(`: an arming scoped to that substitution then reads as
# file-level and the file over-reports, the direction that costs a correct
# edit. The arming test takes the same minimum at the arming position, over the
# line's prefix up to it, so the same holds there: it arms at least wherever the
# raw count arms, and the misalignment can only over-arm.
#
# The script arm applies the same depth test to a FILE, and TWO shapes reach a
# false negative through it, the direction this gate must not be wrong in, so
# neither is left implied by the other.
#
# The first is a multi-line
#
#     out="$(
#       set -o pipefail
#       ...one pipeline into a quiet reader...
#     )"
#
# in a tracked script. It genuinely runs armed inside that subshell, and the
# depth test reads it as arming nothing, so the reader inside goes unreported.
# Before the depth test the script arm caught it by ACCIDENT, by over-arming the
# whole file on any arming it saw anywhere. This arm invents nothing here: the
# identical shape in a `run:` body already reads clean, so what changed is that
# the two arms now agree about it.
#
# The second is a literal `$(` that is DATA rather than code, sitting unbalanced
# on an earlier non-comment line: a `grep -F` pattern, a `printf` template. It
# holds the carry above zero until some later line spends a `)`, so a genuine
# file-level `set -euo pipefail` in between reads as scoped and every reader in
# the file goes unreported. It stands on both arms alike, since both carry
# through the one function. The minimum closes the single-quoted form, and a
# fixture on each arm pins it, only where the span opens and closes on one line
# with no earlier stray quote on that line, because the strip reads one line at
# a time and pairs quotes by position. That scope holds whether the literal sits
# on an earlier line or on the arming's own line, `grep -nF 'x=$(' f; set -euo
# pipefail`, because the arming test takes the same minimum at the arming
# position. Everything outside that stays open on both arms, among it: a literal
# `$(` on a quote-free line inside a single-quoted program spanning several
# lines (an awk or jq body); an apostrophe inside double quotes ahead of the
# literal on the same line, `echo "it's"; grep -nF 'x=$(' f`; a literal `$(` in
# a trailing `#` comment (only a full-line comment is skipped), in a heredoc body
# (a body is scanned as code, whatever its delimiter's quoting), or escaped as
# `\$(` inside double quotes (a backslash is not read). The multi-line program
# and the heredoc body need state carried across lines; the others need a
# tokenizer's reading of one line rather than a character count.
#
# Neither shape changes what this tree reports, and the honest form of that is
# a differential rather than an absence. Run the gate with the cross-line carry
# disabled outright and the armed set and the report come back byte-identical,
# so nothing in this tree has an arming status that turns on the carry. That is
# the claim; it is cheap to re-check and it is the one that matters.
#
# Lines that end at a positive carry are common, and they are not this defect:
# nearly all are genuine multi-line substitutions, which the carry is right to
# scope, and every one is spent by a later `)`, so no tracked file reaches end
# of file still carrying depth. A repair that drove the carry to zero
# everywhere would stop scoping those to correct a handful of literals, which
# is why the strip only ever lowers the carry, and why a fixture pins the script
# arm's cross-line carry directly.
#
# The balanced case, a whole `$( ... )` inside one quoted argument, returns to
# zero on its own line under either count and is pinned by a fixture.
#
# `defaults.run.shell`, at job or workflow level, would move the resolved shell
# for every step under it. This gate REFUSES rather than resolves it: a
# BLOCK-STYLE `defaults:` key anywhere in the scanned YAML exits 4 naming
# gaia-react/gaia#1814. Block-style is the honest qualifier rather than a
# hedge, because it is exactly what the reader below sees: it takes one leading
# mapping key per line, so a flow-style `jobs: {j: {defaults: ...}}` reads as
# the key `jobs` and its nested `defaults:` is never seen. No flow-style
# workflow YAML exists here, and the same one-key-per-line reading is what every
# other structural answer this arm gives is built on. There are zero in this tree, so the refusal costs
# nothing today, and it converts an unimplemented precedence chain into a loud
# stop rather than a silent wrong answer. That is this tree's own idiom, the
# same shape gaia-react/gaia#1880's `--show-prefix` refusal takes ahead of
# discovery. Implementing the chain is a change for the day a `defaults:` key
# first appears, and this diagnostic is what will name it.
#
# BOTH `run:` spellings are scanned. A block scalar is graded when the block
# ends; an inline value is a single command, so it is its own one-line block and
# is graded on the spot. Grading only the block form would leave the inline one
# unscanned at every arming, and a composite step is precisely where that
# matters: the Actions schema makes `shell:` mandatory there, so a `shell: bash`
# arms an inline reader exactly as it arms a block one.
#
# Known blind spots on this surface, stated rather than discovered later, and
# both of them FALSE NEGATIVES. A `run:` whose value is a multi-line plain or
# quoted flow scalar has only its first line read, the rest being scanned as
# though they were not part of the value. A mustache partial include inside a
# body ends the scan there. The first mirrors
# .gaia/scripts/lint-workflow-run-interpolation.sh, which states its own version
# of it and scans the same two arms, and neither shape appears in this tree.
#
# Bash 3.2 compatible. Never `cd`.

set -euo pipefail

readonly PROGRAM_NAME="lint-sigpipe-readers"

# Script-relative, never cwd-relative: every fixture test runs this guard with
# cwd inside a throwaway repo that carries no .gaia/scripts/. Bracketed with
# set +e/-e because this file arms errexit itself, and an unbracketed load
# would abort the script outright if the library were ever present but
# unparseable.
_gaia_guard_library_directory="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_library_directory" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_library_directory="."; fi
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
set +e; [ -f "$_gaia_guard_library_directory/guard-awk-lib.sh" ] && . "$_gaia_guard_library_directory/guard-awk-lib.sh" 2>/dev/null; set -e
type gaia_guard_scan_files >/dev/null 2>&1 || {
  printf '%s: guard-awk-lib.sh is missing beside this script\n' "$PROGRAM_NAME" >&2
  exit 2
}
case "$GAIA_AWK_STATUS" in
  5)
    printf '%s: no awk interpreter found; install mawk (macOS: brew install mawk; Debian/Ubuntu: apt-get install mawk) or ensure /usr/bin/awk is present\n' "$PROGRAM_NAME" >&2
    exit 5
    ;;
  6)
    printf '%s: GAIA_AWK resolved to an unsanctioned interpreter (%s); the sanctioned set is mawk and BWK one-true-awk\n' "$PROGRAM_NAME" "$GAIA_AWK_IDENTITY" >&2
    exit 6
    ;;
esac

# The scan surface comes from the shared library rather than from a read loop
# here, so every gate consuming it discovers the same set the same way and a
# widened pathspec cannot reach one of them and miss the others. The call fills
# GAIA_GUARD_SCAN_FILES and returns non-zero on an empty surface, which is a
# hard error rather than a clean tree; the status is read directly, because a
# substitution would swallow it.
#
# The library's own status is carried out rather than flattened to 1: 1 says the
# tree was read and held nothing, 3 says it was never read at all, and an
# operator handed 1 for the second would look at the tree instead of the
# discovery.
# Each set is copied out of the library's one global before the next call
# overwrites it, because the two arms below ARM differently: the scripts by
# their own text and their source closure, the YAML by its steps' resolved
# shells. A single union call would hand both to one arm and, worse, would let a
# non-empty `shell` set carry an empty `workflows` set past the emptiness check,
# which is the fail-open discovery `.claude/rules/guards-must-fail.md` names.
gaia_guard_scan_files "$PROGRAM_NAME" shell || exit $?
sh_files=(${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"})

# In delta mode `sh_files` is narrowed to the delta, but a script is graded by
# its source closure, and the armed caller that puts a delta library in it can
# sit outside the delta. So the records the closure is built from cover the
# whole tracked set, and only grading and reporting are narrowed. A delta with
# no script reports nothing, so it skips the record pass too.
record_files=(${sh_files[@]+"${sh_files[@]}"})
if [ -n "${GAIA_GUARD_DELTA_FILE:-}" ] && [ "${#sh_files[@]}" -gt 0 ]; then
  GAIA_GUARD_DELTA_FILE='' gaia_guard_scan_files "$PROGRAM_NAME" shell || exit $?
  record_files=(${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"})
fi

gaia_guard_scan_files "$PROGRAM_NAME" workflows || exit $?
yaml_files=(${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"})

# The class detector both arms share lives beside this script, loaded under the
# same bracket as the guard library above.
# shellcheck source=.gaia/scripts/lint-sigpipe-readers-detect.sh
set +e; [ -f "$_gaia_guard_library_directory/lint-sigpipe-readers-detect.sh" ] && . "$_gaia_guard_library_directory/lint-sigpipe-readers-detect.sh" 2>/dev/null; set -e
if [ -z "${READER_AWK:-}" ]; then
  printf '%s: lint-sigpipe-readers-detect.sh is missing beside this script\n' "$PROGRAM_NAME" >&2
  exit 2
fi

# The `*.sh` arm. One pass per file, emitting three tab-separated record kinds
# rather than a verdict, because no file can be graded until the whole closure
# is known:
#
#   #armed  <file>                     the file arms pipefail itself (a seed)
#   #source <file> <basename>          the file loads that basename (an edge)
#   #hit    <file> <line> <message>    a candidate, graded later
readonly SHELL_AWK='
{
  line = $0
  bare = line
  sub(/^[[:space:]]+/, "", bare)

  # A full-line comment neither arms pipefail nor carries an executed reader,
  # and it does NOT close an open pipeline: bash accepts a comment line between
  # a trailing pipe and the command that follows it, so the carry is left alone.
  if (bare ~ /^#/) next

  # The arming test is handed `line`, not the whitespace-stripped `bare` the
  # rest of this block reads, because its locator indexes the string it was
  # given: a stripped one would place every occurrence a few characters early
  # and answer the depth question about the wrong position. The depth is carried
  # to the next line the way the workflow arm carries it, and for the same
  # reason: a substitution opened on one line and closed on another scopes every
  # arming between them.
  if (!armed && arms_at_depth_zero(line)) armed = 1
  substitution_depth = carry_at(line)

  # A source edge. The load token is recognized anywhere a command may start,
  # not at line start only, because the bracketed load this tree uses for an
  # errexit-armed file puts it after a semicolon and an &&.
  if (bare ~ /(^|[^A-Za-z0-9_${}\/.-])(\.|source)[[:space:]]/) {
    if (match(bare, /[A-Za-z0-9_.-]+\.sh/))
      printf "#source\t%s\t%s\n", file, substr(bare, RSTART, RLENGTH)
  }

  line_hit_count = scan_pipeline(line)
  for (i = 1; i <= line_hit_count; i++)
    printf "#hit\t%s\t%d\t`%s` short-circuits a pipeline under pipefail\n", file, FNR, hit_buffer[i]

  previous_line_carries_pipe = carries_pipe(line)
}

# At END, not inline: a file may arm pipefail on a line BELOW a pipeline, so
# where the set sits says nothing about whether the file runs armed.
END { if (armed) printf "#armed\t%s\n", file }
'

# The workflow-YAML arm, and the whole of the shell oracle the header describes.
# Two passes over the same file, named twice on the command line, because a
# step\047s `shell:` key may sit either side of its `run:` key and the block
# cannot be graded until both have been read. Pass one resolves each step\047s
# shell and finds any `defaults:` key; pass two scans the bodies.
#
# Two record kinds, both already graded, because this arm needs no closure:
#
#   #defaults <file> <line>            a construct this gate refuses to resolve
#   #hit      <file> <line> <message>  a reader in a block that runs armed
readonly YAML_AWK='
# The YAML structure both passes walk, reduced to the two questions this gate
# asks of it: which mapping key is this line, and is this line inside a block
# scalar rather than a key at all. Sets keyname, key_column and islist; answers 0
# when the line carries no key to read.
#
# The block-scalar half is load-bearing rather than tidiness, and which cases
# need it is a criterion rather than a list: any caller that acts on this
# answer without the step-column test gating it reads a key at ANY column, so
# it has nothing to fall back on, and a `run:` body carrying whatever shape
# that caller keys on, a quoted keyword or a dash-led item alike, would be
# taken for the key itself. Both passes below carry such callers, the `islist`
# arm among them, since the arm that sets the step column necessarily runs
# ahead of the test against it, and it keys on the dash rather than on any
# word. Take them off the call sites rather than off a list here, which goes
# stale the round another one is added. It is NOT what saves the two lines
# spelled `shell:` inside the `filters: |` body of
# .github/workflows/shell-lint.yml, tempting as that reading is. Block-scalar
# content is necessarily indented deeper than the key that opened it, and that
# key is already deeper than the step column, so the step-column test decides
# those two on its own and would still decide them with this half removed.
function yaml_key(current_line,   column, rest) {
  if (current_line ~ /^[[:space:]]*$/) return 0
  column = match(current_line, /[^ ]/)
  if (block_column >= 0) {
    if (column > block_column) return 0
    block_column = -1
  }
  # A mustache section tag at column 1 renders as a blank line, so it is neither
  # a key nor a dedent. A partial include is deliberately not spared: it splices
  # a whole document region.
  rest = substr(current_line, column)
  if (substr(rest, 1, 3) ~ /^\{\{[#^\/]/) return 0
  # A list item opens a step, and the key after its dash is the first key of
  # that step. The dash and its following run of spaces are part of the
  # indentation for column purposes, so the key column is measured past them.
  islist = 0
  if (match(current_line, /^[[:space:]]*-[[:space:]]+/)) {
    islist = 1
    column = RLENGTH + 1
    rest = substr(current_line, column)
  }
  if (rest !~ /^[A-Za-z_][A-Za-z0-9_.-]*:([[:space:]]|$)/) return 0
  keyname = rest
  sub(/:.*$/, "", keyname)
  key_column = column
  key_value = rest
  sub(/^[A-Za-z_][A-Za-z0-9_.-]*:/, "", key_value)
  # A block scalar header carries nothing but the indicator, its optional
  # chomping and indentation digits in either order, and an optional comment.
  # Anything else on the line is inline content, which is a single command and
  # so cannot carry a two-line shape.
  isblock = (key_value ~ /^[[:space:]]*[|>][-+0-9]*[[:space:]]*(#.*)?$/)
  if (isblock) block_column = key_column
  return 1
}

# A step is armed by its resolved shell when it names bash outright, or names a
# custom invocation carrying pipefail. Everything else, the absent case
# included, is GitHub\047s bare `bash -e` default, which arms nothing.
function shell_arms(shell_value) {
  sub(/^[[:space:]]+/, "", shell_value)
  sub(/[[:space:]]+$/, "", shell_value)
  gsub(/^["\047]|["\047]$/, "", shell_value)
  if (shell_value == "bash") return 1
  return (shell_value ~ /pipefail/)
}

# Close the step pass one is holding: a step that carried a `run:` block and
# resolved to an arming shell hands pass two a pre-armed block, keyed by the
# line its `run:` sits on. An array rather than a record, because the two passes
# are one awk invocation and pass two reads it directly.
function flush_step() {
  if (step_run_line > 0 && shell_arms(stepshell)) shellarm[step_run_line] = 1
  step_run_line = 0
  stepshell = ""
}

BEGIN { block_column = -1; step_run_line = 0; step_key_column = -1 }

# --- pass one: resolve each step\047s shell, and find any defaults: key ------
NR == FNR {
  if (!yaml_key($0)) next
  if (keyname == "defaults") printf "#defaults\t%s\t%d\n", file, FNR
  # A list item opens a step, and its own key column is the column every other
  # key of that step sits at.
  if (islist) { flush_step(); step_key_column = key_column }
  if (key_column != step_key_column) next
  # Both `run:` spellings register, block scalar and inline alike. The resolved
  # shell of the step arms whichever one it carries, so grading only the block
  # form would leave the inline one unscanned at every arming.
  if (keyname == "shell") stepshell = key_value
  else if (keyname == "run") step_run_line = FNR
  next
}

# --- pass two: scan the run: bodies -----------------------------------------
# Reached only on pass two, because the rule above ends in `next`. The last step
# of pass one is still open here, so this is where it closes.
FNR == 1 { flush_step(); block_column = -1; inrun = 0 }

{
  if (inrun) {
    column = match($0, /[^ ]/)
    tag = substr($0, column ? column : 1)
    # A blank line, and a mustache section tag rendering as one, belong to the
    # block scalar rather than ending it.
    if ($0 ~ /^[[:space:]]*$/ || substr(tag, 1, 3) ~ /^\{\{[#^\/]/) { body($0, FNR); next }
    if (column > run_column) { body($0, FNR); next }
    endrun()
    # Fall through: this same line may itself be the next run: key.
  }
  if (yaml_key($0) && keyname == "run") {
    armed = shellarm[FNR]
    substitution_depth = 0
    previous_line_carries_pipe = 0
    pending_count = 0
    if (isblock) {
      inrun = 1
      run_column = key_column
    } else {
      # An inline value is a single command, so it is its own one-line block and
      # is graded on the spot. It needs the same arming as the block form and
      # nothing else: a composite step, where the schema makes `shell:`
      # mandatory, is exactly where a `shell: bash` puts the class on a key\047s
      # own line. The sibling run-interpolation gate scans this arm too, so
      # skipping it here would leave the two disagreeing about the same value.
      body(key_value, FNR)
      endrun()
    }
  }
}

END { if (inrun) endrun() }

# body: one line of a run: block. Hits are BUFFERED rather than printed, because
# a block may arm pipefail on a line below a pipeline exactly as a file may.
function body(current_line, line_number,   i, line_hit_count) {
  bare = current_line
  sub(/^[[:space:]]+/, "", bare)
  # A full-line comment neither arms pipefail nor carries an executed reader,
  # and it does NOT close an open pipeline. It is skipped before the depth walk
  # too: this tree\047s comments quote `$(...)` as prose, and counting those
  # would drift the depth against real code.
  if (bare ~ /^#/) return
  if (!armed && arms_at_depth_zero(current_line)) armed = 1
  substitution_depth = carry_at(current_line)
  line_hit_count = scan_pipeline(current_line)
  for (i = 1; i <= line_hit_count; i++) { pending_count++; pending_line_number[pending_count] = line_number; pending_text[pending_count] = hit_buffer[i] }
  previous_line_carries_pipe = carries_pipe(current_line)
}

# endrun: the block just ended, so this is where it is graded.
function endrun(   i) {
  if (armed)
    for (i = 1; i <= pending_count; i++)
      printf "#hit\t%s\t%d\t`%s` short-circuits a pipeline under pipefail\n", file, pending_line_number[i], pending_text[i]
  inrun = 0
  pending_count = 0
}
'

WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/$PROGRAM_NAME.XXXXXX")" || {
  printf '%s: could not create a scratch directory; nothing was scanned\n' "$PROGRAM_NAME" >&2
  exit 2
}
# Three arms, not one shared arm: bash resumes at the point of interruption once
# a trapped handler returns, so a single arm that only cleans up would leave
# Ctrl-C printing a verdict as if uninterrupted.
trap 'rm -rf "$WORK_DIRECTORY"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The basename-to-path record is emitted here rather than by the awk pass,
# because awk is handed the file CONTENT and this is a fact about its name. It
# rides the same stream as the awk records, so the loop opens one output file
# and forks nothing per file: `${file_path##*/}` is what `basename` would have returned.
#
# `LC_ALL=C` on both arms, so awk reads BYTES rather than characters. See the
# YAML loop below for the hazard; it is if anything stronger here, because far
# more tracked `*.sh` carry a non-ASCII byte than workflow YAML does. Every
# construct either arm matches on is ASCII, so reading bytes costs neither of
# them anything, and the two per-file invocations do not disagree about a
# hazard this file argues is real.
for file_path in ${record_files[@]+"${record_files[@]}"}; do
  [ -f "$file_path" ] || continue
  printf '#file\t%s\t%s\n' "${file_path##*/}" "$file_path"
  LC_ALL=C "$GAIA_AWK" -v file="$file_path" "$READER_AWK$SHELL_AWK" "$file_path"
done > "$WORK_DIRECTORY/records"

# The YAML arm, into its own record stream: its hits arrive already graded, so
# they must not reach the closure machinery below, which grades by file rather
# than by block. Each file is named TWICE, which is what makes the two passes
# two: pass one resolves the steps, pass two scans the bodies.
#
# `LC_ALL=C` for the reason the `*.sh` loop above also takes it: the prose in
# these files is not ASCII (an arrow in a comment of the code-review-audit
# template is enough), and awk aborts the whole file on a multibyte conversion
# failure, which would leave the arm scanning nothing and saying so only as a
# warning on stderr. Every construct this arm matches on -- YAML indentation,
# `run:`, `shell:`, the pipe, the reader flags -- is ASCII.
for file_path in ${yaml_files[@]+"${yaml_files[@]}"}; do
  [ -f "$file_path" ] || continue
  LC_ALL=C "$GAIA_AWK" -v file="$file_path" "$READER_AWK$YAML_AWK" "$file_path" "$file_path"
done > "$WORK_DIRECTORY/yaml-records"

# The refusal, ahead of any verdict. A `defaults:` key moves the resolved shell
# for every step under it, which is the one thing the oracle above does not
# resolve, so the gate stops rather than answer for a surface it has graded on
# the wrong default. Read with a single awk pass rather than a quiet grep
# downstream of a pipe: this file arms pipefail, and that is the class it
# exists to catch.
defaults_seen="$("$GAIA_AWK" -F'\t' '$1 == "#defaults" { printf "%s:%s\n", $2, $3 }' "$WORK_DIRECTORY/yaml-records")"
if [ -n "$defaults_seen" ]; then
  printf '%s\n' "$defaults_seen" >&2
  cat >&2 <<REFUSAL
$PROGRAM_NAME: a \`defaults:\` key is present in the scanned workflow YAML, at the
line(s) above. It moves the resolved shell for every \`run:\` step beneath it,
and this gate resolves a step's own \`shell:\` key only. Grading these steps
would answer from the wrong default, so nothing was graded. Implementing the
step-over-job-over-workflow precedence chain is tracked as gaia-react/gaia#1814.
REFUSAL
  exit 4
fi

# Split the one record stream into the three inputs the closure needs. No `||`
# guard is owed on any of them: awk exits 0 over a file holding no matching
# record, so a record kind the tree never produced yields an empty file rather
# than a failure under this script's own errexit.
"$GAIA_AWK" -F'\t' '$1 == "#armed"  { print $2 }' "$WORK_DIRECTORY/records" | LC_ALL=C sort -u > "$WORK_DIRECTORY/closure"
"$GAIA_AWK" -F'\t' '$1 == "#source" { printf "%s\t%s\n", $2, $3 }' "$WORK_DIRECTORY/records" > "$WORK_DIRECTORY/edges"
"$GAIA_AWK" -F'\t' '$1 == "#hit"    { print }' "$WORK_DIRECTORY/records" > "$WORK_DIRECTORY/hits"
"$GAIA_AWK" -F'\t' '$1 == "#file"   { printf "%s\t%s\n", $2, $3 }' "$WORK_DIRECTORY/records" | LC_ALL=C sort -u > "$WORK_DIRECTORY/index"

# Transitive closure over the source edges. A fixed-point loop rather than a
# recursive walk, because bash 3.2 has no associative array to memoize with and
# the tracked set is small enough that re-resolving the whole frontier each
# round is cheaper than the bookkeeping that would avoid it.
while : ; do
  "$GAIA_AWK" -F'\t' 'NR == FNR { seed[$0] = 1; next } ($1 in seed) { print $2 }' \
    "$WORK_DIRECTORY/closure" "$WORK_DIRECTORY/edges" | LC_ALL=C sort -u > "$WORK_DIRECTORY/bases"
  "$GAIA_AWK" -F'\t' 'NR == FNR { want[$0] = 1; next } ($1 in want) { print $2 }' \
    "$WORK_DIRECTORY/bases" "$WORK_DIRECTORY/index" | LC_ALL=C sort -u > "$WORK_DIRECTORY/reached"
  LC_ALL=C comm -13 "$WORK_DIRECTORY/closure" "$WORK_DIRECTORY/reached" > "$WORK_DIRECTORY/added"
  [ -s "$WORK_DIRECTORY/added" ] || break
  LC_ALL=C sort -u "$WORK_DIRECTORY/closure" "$WORK_DIRECTORY/added" > "$WORK_DIRECTORY/closure.next"
  mv "$WORK_DIRECTORY/closure.next" "$WORK_DIRECTORY/closure"
done

report=""
for file_path in ${sh_files[@]+"${sh_files[@]}"}; do
  grep -qxF -- "$file_path" "$WORK_DIRECTORY/closure" || continue
  hits="$("$GAIA_AWK" -F'\t' -v file_path="$file_path" '$2 == file_path { printf "%s:%s: %s\n", $2, $3, $4 }' "$WORK_DIRECTORY/hits")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done

# No closure test on this arm: a `run:` body is its own script, so it is graded
# by its own step and inherits nothing from the file around it.
for file_path in ${yaml_files[@]+"${yaml_files[@]}"}; do
  hits="$("$GAIA_AWK" -F'\t' -v file_path="$file_path" '$1 == "#hit" && $2 == file_path { printf "%s:%s: %s\n", $2, $3, $4 }' "$WORK_DIRECTORY/yaml-records")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  # The remedy is written as prose rather than as sample pipelines, so the
  # footer this gate prints cannot read as an instance of the class it reports.
  cat >&2 <<'REMEDY'
Fix each by removing the pipeline rather than making the race safer:
    a printf or echo feeding the reader  ->  grep -q RE <<<"$var"
    a command feeding the reader         ->  out="$(some_command)"
                                             grep -q RE <<<"$out"
    a filter feeding the reader          ->  one awk pass over <<<"$var"
An inverted reader (grep -qv, grep -qvF) additionally needs the newline <<< appends
trimmed off the value, or it succeeds on the trailing blank line unconditionally.
A file with no `set -o pipefail` of its own still counts when an armed file sources it.
REMEDY
  exit 1
fi

printf '%s: clean\n' "$PROGRAM_NAME" >&2
exit 0
