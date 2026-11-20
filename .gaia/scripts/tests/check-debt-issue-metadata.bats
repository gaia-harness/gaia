#!/usr/bin/env bats
# Tests for .gaia/scripts/check-debt-issue-metadata.sh, the filing-time gate over
# a tech-debt issue's label set and dedup key.
#
# Most tests drive `--pre-file`, the blocking mode, which reads no network and
# needs no `gh`. The two advisory modes (`--issue`, `--sweep`) share all of their
# checking with `--pre-file` through `check_labels` / `check_body`, so the
# offline tests cover that logic once for all three.
#
# What the gh modes add on top is transport, and that is covered here through a
# `gh` stub placed on PATH rather than against the real tracker: a stub makes
# the whole surface hermetic and deterministic, including the arms a live
# tracker cannot be made to exhibit on demand (an empty backlog, a `gh` that
# fails), and a live backlog would also be data that changes under the test.
#
# The suite's job is to prove each guard can FAIL. A gate is only worth its
# context if the red case is demonstrated: the green case is already green
# before the gate exists, so a test that only asserts clean-stays-clean asserts
# nothing about the gate. Each check below therefore gets a fixture built to
# trip it, and the exit status plus the emitted finding code are both asserted,
# because a gate that fails for the wrong reason is a gate that will pass for
# the wrong reason later.
#
# Two of the fixtures are the live defects that motivated the gate, the first
# row of their case tables: an issue filed with no `audience:` label, and an
# issue filed with no dedup key at all.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md. Note the
# `run` idiom throughout, which captures status instead of letting a non-zero
# exit abort the test body; `$status` is then compared with POSIX `[ ]`.

setup() {
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$THIS_DIRECTORY/../../.." && pwd)"
  CHECK="$REPO_ROOT/.gaia/scripts/check-debt-issue-metadata.sh"
  TEMPORARY_DIRECTORY="$(mktemp -d -t debt-issue-metadata-XXXXXX)"
  BODY="$TEMPORARY_DIRECTORY/body.md"
  good_body >"$BODY"
}

teardown() {
  [ -n "${TEMPORARY_DIRECTORY:-}" ] && [ -d "$TEMPORARY_DIRECTORY" ] && rm -rf "$TEMPORARY_DIRECTORY"
  return 0
}

# A body that satisfies every body-side check: one well-formed dedup key and
# the schema's prose parts.
good_body() {
  cat <<'EOF'
<!-- gaia-debt-key: v1 class=holistic/unclassified path=app/services/foo.ts line=42 -->
`app/services/foo.ts:42`

## Failure mode

A null `userId` reaches this branch and throws.

## Suggested fix

Guard the branch.
EOF
}

# A body that additionally satisfies the `severity:investigate` research block:
# the marker line plus both of its labelled lines, each carrying text.
good_investigate_body() {
  good_body
  cat <<'EOF'

<!-- gaia-investigate: v1 -->
**Question:** does the fail-open branch ever run with a non-empty allowlist?
**Settled by:** a test that drives the branch with an allowlist of one entry.
EOF
}

# The label set a correct graded filing carries.
GOOD_LABELS='tech-debt,severity:major,audience:adopter,footprint:narrow,difficulty:easy'

# The label set an investigate filing carries. No difficulty grade: a filing
# that cannot grade the severity has not read the code closely enough to grade
# the fix either, so the two absences travel together.
INVESTIGATE_LABELS='tech-debt,severity:investigate,audience:adopter,footprint:narrow'

# assert_code <finding-code>: the run's output names this finding code.
assert_code() {
  grep -qF -- "$1" <<<"$output" || return 1
}

# refute_code <finding-code>: written as a positive match plus an explicit
# `return 1` rather than a `!`-negation, which `set -e` exempts.
refute_code() {
  grep -qF -- "$1" <<<"$output" && return 1
  return 0
}

# write_body <kind>: writes the named body fixture to $BODY.
write_body() {
  case "$1" in
    good) good_body >"$BODY" ;;
    investigate) good_investigate_body >"$BODY" ;;
    investigate-empty-question)
      {
        good_body
        printf '\n<!-- gaia-investigate: v1 -->\n**Question:**\n**Settled by:** a test that drives the branch.\n'
      } >"$BODY"
      ;;
    investigate-no-settled-by)
      {
        good_body
        printf '\n<!-- gaia-investigate: v1 -->\n**Question:** does the branch ever run?\n'
      } >"$BODY"
      ;;
    investigate-second-block)
      {
        good_investigate_body
        printf '\n<!-- gaia-investigate: v1 -->\n**Question:** a second, contradicting question.\n**Settled by:** something else.\n'
      } >"$BODY"
      ;;
    investigate-prose-mention)
      # A correction comment quoting the block's format indents or inlines the
      # marker, so it matches none of the anchored patterns. A flush-left quote
      # of the whole fence is a different case and does trip the gate.
      {
        good_body
        printf '\nThe schema is `<!-- gaia-investigate: v1 -->` followed by two lines.\n'
        printf '\n  <!-- gaia-investigate: v1 -->\n'
      } >"$BODY"
      ;;
    investigate-crlf)
      # A body last edited in the web UI arrives with a trailing carriage
      # return on every line.
      good_investigate_body | sed 's/$/\r/' >"$BODY"
      ;;
    key-absent) printf 'a body with prose and no key at all\n' >"$BODY" ;;
    key-non-integer-line)
      printf '<!-- gaia-debt-key: v1 class=holistic/unclassified path=app/foo.ts line=forty -->\n' >"$BODY"
      ;;
    key-duplicate)
      {
        good_body
        printf '<!-- gaia-debt-key: v1 class=holistic/unclassified path=app/bar.ts line=7 -->\n'
      } >"$BODY"
      ;;
    key-malformed-beside-valid)
      # A valid key must not make the later checks unreachable: the stray line
      # would enter the residue tally's suppression set.
      {
        good_body
        printf '<!-- gaia-debt-key: v1 class=x path=app/bogus.ts line=nope -->\n'
      } >"$BODY"
      ;;
    key-prose-only)
      printf 'This issue predates the `<!-- gaia-debt-key: -->` wrapper entirely.\n' >"$BODY"
      ;;
    key-absolute-path)
      printf '<!-- gaia-debt-key: v1 class=holistic/unclassified path=/Users/you/app/foo.ts line=42 -->\n' >"$BODY"
      ;;
    key-trailing-r)
      # The tolerance for CRLF is a `tr`, not a `\r?` in the pattern: that
      # escape matches a carriage return on BSD and a literal `r` on Linux.
      printf '<!-- gaia-debt-key: v1 class=c path=app/a.ts line=1 -->r\n' >"$BODY"
      ;;
    key-path-with-spaces)
      printf '<!-- gaia-debt-key: v1 class=holistic/unclassified path=wiki/concepts/PR Merge Workflow.md line=175 -->\n' >"$BODY"
      ;;
    key-prose-mention-beside-key)
      {
        good_body
        printf 'Exactly one carries a dedup key, in bare form rather than the `<!-- gaia-debt-key: -->` wrapper.\n'
      } >"$BODY"
      ;;
    *)
      echo "write_body: unknown kind $1" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Green baseline
# ---------------------------------------------------------------------------

@test "a clean filing passes" {
  local row kind labels refuted
  for row in \
    "good|$GOOD_LABELS|" \
    "good|tech-debt,severity:minor,audience:maintainer|" \
    "investigate|$INVESTIGATE_LABELS|severity-value" \
    "investigate-prose-mention|$GOOD_LABELS|stray-investigate-block" \
    "investigate-crlf|$INVESTIGATE_LABELS|missing-investigate-block" \
    "good|tech-debt,severity:major,audience:adopter,footprint:narrow|" \
    "good|tech-debt,severity:major,audience:adopter,footprint:wide|" \
    "good|tech-debt,severity:major,audience:adopter,footprint:spec|" \
    "key-path-with-spaces|$GOOD_LABELS|" \
    "key-prose-mention-beside-key|$GOOD_LABELS|"; do
    IFS='|' read -r kind labels refuted <<<"$row"
    write_body "$kind"
    run bash "$CHECK" --pre-file --labels "$labels" --body-file "$BODY"
    [ "$status" -eq 0 ] || { echo "row $row: status $status"; return 1; }
    assert_code "clean" || { echo "row $row: not reported clean"; return 1; }
    if [ -n "$refuted" ]; then
      refute_code "$refuted" || { echo "row $row: reported $refuted"; return 1; }
    fi
  done
}

# ---------------------------------------------------------------------------
# Labels: the namespaces and the labels that belong to another lifecycle stage
# ---------------------------------------------------------------------------

@test "a filing with a missing, duplicated or out-of-set label value is rejected" {
  # The first row is the live defect that motivated the gate: an issue filed
  # with no audience: label. Fields: labels | expected code | code that must
  # not appear | expected finding total (empty to skip).
  local row labels code refuted total
  for row in \
    'tech-debt,severity:major,difficulty:easy|audience-count||' \
    "$GOOD_LABELS,audience:maintainer|audience-count||" \
    'tech-debt,severity:major,audience:internal|audience-value||' \
    'tech-debt,audience:adopter|severity-count||' \
    "$GOOD_LABELS,severity:critical|severity-count||" \
    'tech-debt,severity:blocker,audience:adopter|severity-value||' \
    "$GOOD_LABELS,difficulty:hard|difficulty-count||" \
    'tech-debt,severity:major,audience:adopter,difficulty:trivial|difficulty-value||' \
    "$GOOD_LABELS,footprint:spec|footprint-count||" \
    'tech-debt,severity:major,audience:adopter,footprint:agent|footprint-value||' \
    'tech-debt,severity:,audience:adopter|severity-value|severity-count|' \
    'tech-debt,severity:major,audience:adopter,difficulty:|difficulty-value||' \
    'tech-debt,severity:major,audience:adopter maintainer|audience-value||' \
    'tech-debt,severity:major,audience:*|audience-value|CHANGELOG.md|1' \
    'severity:major,audience:adopter|missing-tech-debt||' \
    "$GOOD_LABELS,in-progress|drain-label-on-new-filing||" \
    "$GOOD_LABELS,debt:spec-pending|drain-label-on-new-filing||" \
    "$GOOD_LABELS,debt:spec-active|drain-label-on-new-filing||"; do
    IFS='|' read -r labels code refuted total <<<"$row"
    run bash "$CHECK" --pre-file --labels "$labels" --body-file "$BODY"
    [ "$status" -eq 1 ] || { echo "row $labels: status $status"; return 1; }
    assert_code "$code" || { echo "row $labels: no $code finding"; return 1; }
    # An empty value is one label with one wrong value, so the count check
    # must stay quiet; a glob must be one finding, never expanded against the
    # working directory into one per repository-root entry.
    if [ -n "$refuted" ]; then
      refute_code "$refuted" || { echo "row $labels: reported $refuted"; return 1; }
    fi
    if [ -n "$total" ]; then
      grep -qF -- "$total finding(s)" <<<"$output" || { echo "row $labels: not $total finding(s)"; return 1; }
    fi
  done
}

# ---------------------------------------------------------------------------
# severity:investigate and its research block
#
# `investigate` is the one severity value that costs something to pick: the
# gate demands the admission of not knowing be specific. Both directions are
# checked, because a block left behind by a re-grade asserts an open question
# that has since been answered.
# ---------------------------------------------------------------------------

@test "an investigate filing without a well-formed research block is rejected" {
  local row kind labels code refuted
  for row in \
    "good|$INVESTIGATE_LABELS|missing-investigate-block|" \
    "investigate-empty-question|$INVESTIGATE_LABELS|investigate-question|missing-investigate-block" \
    "investigate-no-settled-by|$INVESTIGATE_LABELS|investigate-settled-by|" \
    "investigate-second-block|$INVESTIGATE_LABELS|duplicate-investigate-block|" \
    "investigate|$GOOD_LABELS|stray-investigate-block|"; do
    IFS='|' read -r kind labels code refuted <<<"$row"
    write_body "$kind"
    run bash "$CHECK" --pre-file --labels "$labels" --body-file "$BODY"
    [ "$status" -eq 1 ] || { echo "row $row: status $status"; return 1; }
    assert_code "$code" || { echo "row $row: no $code finding"; return 1; }
    # Two findings for one defect sends the filer to fix the wrong thing.
    if [ -n "$refuted" ]; then
      refute_code "$refuted" || { echo "row $row: reported $refuted"; return 1; }
    fi
  done
}

# ---------------------------------------------------------------------------
# The dedup key
# ---------------------------------------------------------------------------

@test "a filing with a missing or malformed dedup key is rejected" {
  # The first row is the live defect that motivated the gate: an issue filed
  # with no dedup key at all.
  local row kind code refuted
  for row in \
    'key-absent|missing-dedup-key|' \
    'key-non-integer-line|malformed-dedup-key|missing-dedup-key' \
    'key-duplicate|duplicate-dedup-key|' \
    'key-malformed-beside-valid|malformed-dedup-key|' \
    'key-prose-only|missing-dedup-key|malformed-dedup-key' \
    'key-absolute-path|dedup-key-path|malformed-dedup-key' \
    'key-trailing-r|malformed-dedup-key|'; do
    IFS='|' read -r kind code refuted <<<"$row"
    write_body "$kind"
    run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY"
    [ "$status" -eq 1 ] || { echo "row $kind: status $status"; return 1; }
    assert_code "$code" || { echo "row $kind: no $code finding"; return 1; }
    if [ -n "$refuted" ]; then
      refute_code "$refuted" || { echo "row $kind: reported $refuted"; return 1; }
    fi
  done
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

@test "every finding is reported, not just the first" {
  # Also the regression pin for the counter: `finding` increments a variable in
  # the caller's shell, so a check that loops in a subshell would report its
  # findings and lose the count, exiting 0 with findings on stdout.
  printf 'no key at all\n' >"$BODY"
  run bash "$CHECK" --pre-file --labels 'severity:major,severity:critical' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "missing-tech-debt"
  assert_code "severity-count"
  assert_code "audience-count"
  assert_code "missing-dedup-key"
  grep -qF -- "4 finding(s)" <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# The two advisory gh modes, driven through a stub
#
# `stub_gh <corpus-json> [view-json]` puts a `gh` on PATH ahead of any real one
# and makes it answer `issue list` with <corpus-json> and `issue view` with
# [view-json]. `stub_gh_failing` makes every call exit non-zero, which is how
# the environment-error arm is reached without breaking anyone's auth.
# ---------------------------------------------------------------------------

# stub_gh <corpus-json> [view-json] [unfiltered-corpus-json]
#
# With a third argument the stub answers BY ARGV rather than by subcommand: a
# list carrying `--label severity:investigate` gets <corpus-json>, any other
# list gets <unfiltered-corpus-json>. That is what lets a test assert the cap's
# BEHAVIOUR instead of its argv shape. An argv assertion cannot tell the query
# whose length becomes the count from any other logged query, so a refactor
# that keeps the filtered query for the refusal numbers and counts a second,
# unfiltered one passes every argv check while refusing every investigate
# filing permanently. Answering per-argv makes that refactor read the larger
# corpus and trip the cap, which no rewording can evade.
#
# Omitting the third argument keeps the subcommand-only behaviour the --issue
# and --sweep tests were written against.
stub_gh() {
  mkdir -p "$TEMPORARY_DIRECTORY/bin"
  printf '%s\n' "$1" >"$TEMPORARY_DIRECTORY/corpus.json"
  printf '%s\n' "${2:-[]}" >"$TEMPORARY_DIRECTORY/view.json"
  if [ "$#" -ge 3 ]; then
    printf '%s\n' "$3" >"$TEMPORARY_DIRECTORY/unfiltered.json"
  else
    rm -f "$TEMPORARY_DIRECTORY/unfiltered.json"
  fi
  cat >"$TEMPORARY_DIRECTORY/bin/gh" <<'EOF'
#!/usr/bin/env bash
# $1 is `issue`, $2 is the subcommand. argv is also logged one call per line, as
# a cheaper backstop to the per-argv corpus selection above.
printf '%s\n' "$*" >>"$STUB_DIRECTORY/argv.log"
case "$2" in
  list)
    if [ -f "$STUB_DIRECTORY/unfiltered.json" ] &&
      ! printf '%s\n' "$*" | grep -qF -- '--label severity:investigate'; then
      cat "$STUB_DIRECTORY/unfiltered.json"
    else
      cat "$STUB_DIRECTORY/corpus.json"
    fi
    ;;
  view) cat "$STUB_DIRECTORY/view.json" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TEMPORARY_DIRECTORY/bin/gh"
  export STUB_DIRECTORY="$TEMPORARY_DIRECTORY"
  export PATH="$TEMPORARY_DIRECTORY/bin:$PATH"
}

stub_gh_failing() {
  mkdir -p "$TEMPORARY_DIRECTORY/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$TEMPORARY_DIRECTORY/bin/gh"
  chmod +x "$TEMPORARY_DIRECTORY/bin/gh"
  export PATH="$TEMPORARY_DIRECTORY/bin:$PATH"
}

@test "--sweep reports an empty backlog rather than reporting a clean check" {
  stub_gh '[]'
  run bash "$CHECK" --sweep
  [ "$status" -eq 0 ]
  grep -qF -- "nothing was checked" <<<"$output" || return 1
}

@test "--sweep applies the shared label and body checks to a live-shaped corpus" {
  stub_gh '[
    {"number":300,
     "labels":[{"name":"tech-debt"},{"name":"severity:major"}],
     "body":"no key here"}
  ]'
  run bash "$CHECK" --sweep
  [ "$status" -eq 1 ]
  assert_code "audience-count"
  assert_code "missing-dedup-key"
}

@test "a CRLF body from the web UI is not reported as a malformed key" {
  # GitHub returns the line endings the client submitted, and a browser textarea
  # submits CRLF, so an issue last edited in the web UI carries a trailing \r.
  # The drain's own capture is unanchored and accepts it; this gate must too.
  stub_gh '[
    {"number":400,
     "labels":[{"name":"tech-debt"},{"name":"severity:major"},{"name":"audience:adopter"}],
     "body":"<!-- gaia-debt-key: v1 class=c path=app/a.ts line=1 -->\r\nsome prose\r\n"}
  ]'
  run bash "$CHECK" --sweep
  [ "$status" -eq 0 ]
}

@test "--issue reports on a single issue through the same shared checks" {
  stub_gh '[]' '{
    "number":200,
    "labels":[{"name":"tech-debt"},{"name":"severity:major"}],
    "body":"no key here"
  }'
  run bash "$CHECK" --issue 200
  [ "$status" -eq 1 ]
  assert_code "audience-count"
  assert_code "missing-dedup-key"
}

# ---------------------------------------------------------------------------
# --investigate-cap: the bounded queue
#
# The cap is the forcing function. The research block above makes one
# investigate filing honest; the cap is what keeps the grade from becoming a
# graveyard, by rationing it. Over the cap a filing is refused with two exits,
# and both are the outcome the axis wants: drain one of the open ones, or grade
# this finding yourself because the "I do not know" budget is spent.
#
# It reports as an ordinary finding (exit 1) rather than a new exit code, so the
# script keeps its three-way contract: 0 clean, 1 fix something and retry, 2 the
# check did not run.
# ---------------------------------------------------------------------------

@test "--investigate-cap no-ops on a filing that is not investigate-graded, without reading the network" {
  # `stub_gh_failing` is the assertion: a mode that consulted gh here would
  # exit 2, so a clean exit proves the short-circuit happened before the read.
  stub_gh_failing
  run bash "$CHECK" --investigate-cap --labels "$GOOD_LABELS"
  [ "$status" -eq 0 ]
}

@test "--investigate-cap passes an investigate filing while the queue is under the cap" {
  stub_gh '[{"number":11,"title":"one"},{"number":12,"title":"two"}]'
  run bash "$CHECK" --investigate-cap --labels "$INVESTIGATE_LABELS"
  [ "$status" -eq 0 ]
}

@test "--investigate-cap refuses a filing that would exceed the cap, and names the queue" {
  local corpus
  for corpus in \
    '[{"number":11,"title":"one"},{"number":12,"title":"two"},{"number":13,"title":"three"}]' \
    '[{"number":11,"title":"one"},{"number":12,"title":"two"},{"number":13,"title":"three"},{"number":14,"title":"four"}]'; do
    stub_gh "$corpus"
    run bash "$CHECK" --investigate-cap --labels "$INVESTIGATE_LABELS"
    [ "$status" -eq 1 ] || { echo "corpus $corpus: status $status"; return 1; }
    assert_code "investigate-cap-reached" || { echo "corpus $corpus: no cap finding"; return 1; }
    # The open numbers are the whole point of the refusal: a filer told only
    # "full" has nothing to act on, and both exits out of it need the list.
    grep -qF -- "#11" <<<"$output" || { echo "corpus $corpus: #11 not named"; return 1; }
    grep -qF -- "#13" <<<"$output" || { echo "corpus $corpus: #13 not named"; return 1; }
  done
}

@test "RED: the cap counts the investigate queue, not the whole open backlog" {
  # One investigate issue against a five-issue open backlog. Whichever corpus
  # the cap actually counts decides the exit status, so this asserts the
  # behaviour: a query that lost the grade filter reads five, trips the cap of
  # three, and reds here. The arithmetic tests above cannot catch that, because
  # they let one corpus answer every list.
  stub_gh '[{"number":11,"title":"one"}]' '[]' \
    '[{"number":21},{"number":22},{"number":23},{"number":24},{"number":25}]'
  run bash "$CHECK" --investigate-cap --labels "$INVESTIGATE_LABELS"
  [ "$status" -eq 0 ]

  # The argv pin stays as the cheaper backstop, and all three filters must sit
  # on ONE logged query: file-wide greps would pass on a split into two calls.
  # EVERY grade-bearing query is checked, not the first: pinning only the first
  # let a refactor keep the correct query for the refusal numbers and count a
  # second grade-bearing one that had lost --state open, which reads the closed
  # investigate issues into the cap while both halves of this test stay green.
  local line found=0
  while IFS= read -r line; do
    found=1
    grep -qF -- "--label tech-debt" <<<"$line" || return 1
    grep -qF -- "--state open" <<<"$line" || return 1
  done < <(grep -F -- "--label severity:investigate" "$TEMPORARY_DIRECTORY/argv.log")
  [ "$found" -eq 1 ] || return 1
}

@test "--investigate-cap on a gh failure exits 2, never the findings status" {
  # The caller treats 2 as advisory and files anyway: refusing every filing
  # while GitHub is unreachable loses findings, and a bound that leaks by one
  # on a network blip is still a bound. Exit 2 is what makes that distinction
  # available to the caller at all.
  stub_gh_failing
  run bash "$CHECK" --investigate-cap --labels "$INVESTIGATE_LABELS"
  [ "$status" -eq 2 ]
}

@test "--investigate-cap --repo counts the named repository's queue, and without it names none" {
  stub_gh '[{"number":11,"title":"one"}]'
  run bash "$CHECK" --investigate-cap --labels "$INVESTIGATE_LABELS" --repo owner/name
  [ "$status" -eq 0 ]
  grep -F -- "--label severity:investigate" "$TEMPORARY_DIRECTORY/argv.log" | grep -qF -- "--repo owner/name" || return 1

  : >"$TEMPORARY_DIRECTORY/argv.log"
  run bash "$CHECK" --investigate-cap --labels "$INVESTIGATE_LABELS"
  [ "$status" -eq 0 ]
  grep -qF -- "--label severity:investigate" "$TEMPORARY_DIRECTORY/argv.log" || return 1
  grep -F -- "--label severity:investigate" "$TEMPORARY_DIRECTORY/argv.log" | grep -qF -- "--repo" && return 1
  true
}

# --- the marker-stripped (adopter) shape of this script ---------------------
#
# The `audience:` namespace is maintainer-only: its rubric's tie-breaker ("a
# release-excluded path is audience:maintainer") is uncomputable on an adopter
# clone, so the declaration and the enforcement block both sit behind
# `# gaia:maintainer-only` markers and leave the bundle (gaia-react/gaia#1437).
#
# The hazard that wrap creates is a runtime one, not a syntax one. Under
# `set -euo pipefail` a strip that took the `AUDIENCE_VALUES` declaration but
# left its `check_namespace_values` reader behind aborts on an unbound variable at the
# FIRST filing, taking the severity, difficulty, and footprint checks down
# with it, and `bash -n` parses that file clean. So these tests strip through
# the real shipped stripper (`gaia-maintainer release scrub`, never a second
# parser written here) and then RUN the result.
#
# Only the stripped shape is tested here. The unstripped half needs nothing new:
# the `audience:` tests above already prove the axis stays mandatory, and
# the wrap changes nothing they read.
#
# Maintainer-only by construction: this suite is release-excluded, and so is
# the `gaia-maintainer` binary it drives. A clone without the binary skips
# rather than fails, so the absence never reads as a passing guard.
#
# require_stripper runs in each @test body rather than inside the helper, and
# that placement is the whole point: bats implements `skip` as `exit 0`, and
# the helper is called as `$(stripped_check)`, so a `skip` there would unwind
# only the substitution subshell. The test would carry on with an empty path
# and die at exit 127 on `bash ""`, which is the opposite of the skip the
# paragraph above promises.
require_stripper() {
  [ -x "$REPO_ROOT/.gaia/cli/gaia-maintainer" ] \
    || skip "maintainer CLI absent; nothing to strip through"
}

# sh_marker_delimiter <start|end>: echo that delimiter, quotes included, from the
# one marker-strip transform in `.gaia/release-scrub.yml` whose paths cover
# `**/*.sh`, which is the transform that governs the script under test.
sh_marker_delimiter() {
  awk -v want="$1" '
    /^  - type: / {in_block = ($0 == "  - type: marker-strip"); covers_sh = 0; next}
    !in_block {next}
    $0 == "      - \"**/*.sh\"" {covers_sh = 1; next}
    covers_sh && index($0, "    " want ": ") == 1 {
      sub(/^    [a-z]+: /, "", $0)
      print $0
      exit
    }
  ' "$REPO_ROOT/.gaia/release-scrub.yml"
}

# delimiter_missing <start|end>: name which delimiter key could not be read, and
# which of the two contracts moved. A literal format string, not the message in
# a variable, so shellcheck reads it as one.
delimiter_missing() {
  printf 'sh_marker_delimiter: no `%s:` under the `**/*.sh` marker-strip transform in .gaia/release-scrub.yml; that YAML shape moved, not the strip\n' "$1" >&2
}

# stripped_check: strip the script into a throwaway staging tree and echo the
# stripped path. Call `require_stripper` in the test body first.
stripped_check() {
  local cli="$REPO_ROOT/.gaia/cli/gaia-maintainer"

  local stage="$TEMPORARY_DIRECTORY/stage"
  mkdir -p "$stage/.gaia/scripts"
  cp "$CHECK" "$stage/.gaia/scripts/check-debt-issue-metadata.sh"

  # Only the `**/*.sh` marker-strip transform, so no sibling leak-check can
  # decide this test's outcome. Its delimiters are READ from the shipped config
  # rather than restated: the shipped parser is only half the contract, and a
  # second copy of the spellings would leave this suite stripping and passing
  # against a retired one while the real release strip took nothing out of this
  # script. Asserting the spellings are present somewhere in that file is not
  # enough, because a sibling transform there carries the same two spellings
  # and does not cover `**/*.sh`; the block has to be the one that governs
  # this file.
  local start end
  start="$(sh_marker_delimiter start)"
  end="$(sh_marker_delimiter end)"
  # Say which side of the contract moved. The bare `return 1` this replaces
  # surfaced in bats as the caller's `|| return 1` and nothing else, so a
  # shape-preserving edit to that transform (re-quoting the path entry, or
  # ordering `start:`/`end:` ahead of `paths:`) read as an unexplained failure
  # of the strip itself.
  [ -n "$start" ] || { delimiter_missing start; return 1; }
  [ -n "$end" ] || { delimiter_missing end; return 1; }

  cat >"$TEMPORARY_DIRECTORY/scrub.yml" <<YAML
transforms:
  - type: marker-strip
    paths:
      - "**/*.sh"
    start: $start
    end: $end
YAML

  "$cli" release scrub "$stage" --config "$TEMPORARY_DIRECTORY/scrub.yml" >/dev/null || return 1
  printf '%s\n' "$stage/.gaia/scripts/check-debt-issue-metadata.sh"
}

@test "the stripped script drops the audience requirement: a filing with no audience: label is clean" {
  require_stripper
  local stripped
  stripped="$(stripped_check)" || return 1

  grep -qF -- 'AUDIENCE_VALUES' "$stripped" && return 1

  run bash "$stripped" --pre-file \
    --labels 'tech-debt,severity:major,footprint:narrow,difficulty:easy' \
    --body-file "$BODY"
  [ "$status" -eq 0 ]
}

@test "the stripped script still RUNS every surviving check rather than aborting on an unbound variable" {
  # The finding CODES are the assertion, not the exit status. An unbound-
  # variable abort also exits non-zero, so a status-only test would green on
  # the exact defect this exists to catch. Each code below is emitted from a
  # line AFTER the stripped block, so seeing every one proves execution reached
  # the end of `check_labels`.
  require_stripper
  local stripped
  stripped="$(stripped_check)" || return 1

  run bash "$stripped" --pre-file \
    --labels 'tech-debt,severity:blocker,difficulty:trivial,footprint:agent' \
    --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "severity-value"
  assert_code "difficulty-value"
  assert_code "footprint-value"
  refute_code "unbound variable"
}
