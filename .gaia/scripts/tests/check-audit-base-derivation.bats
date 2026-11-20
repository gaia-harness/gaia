#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-audit-base-derivation.sh, the
# static check keeping the Code Audit Team definitions on one review
# base. The behavioral suite next door
# (.gaia/scripts/tests/audit-base-agreement.bats) proves they agree by
# executing their real snippets; this one proves the STATIC check that stops
# them drifting apart actually fires, which a green run can never show on
# its own.
#
# Every test except the two marked "real repo" drives the check against a
# FIXTURE tree it builds, never the real repo, so "would this shape fail the
# check" is answerable without doctoring tracked source.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-audit-base-derivation.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIRECTORY/check-audit-base-derivation.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-audit-base-derivation.sh
  source "$CHECK"
}

# Fixtures live under $BATS_TEST_TMPDIR, which bats removes after each test,
# so this file keeps no cleanup bookkeeping of its own (the sibling
# audit-base-agreement.bats does the same). A tracked list would not work
# here anyway: every call site is a command substitution, so an append made
# inside this function lands in a subshell copy and never reaches teardown.
make_fixture_repo() {
  local name="$1"
  local directory="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$directory/.claude/agents"
  git init -q --initial-branch=main "$directory"
  git -C "$directory" config user.email t@example.com
  git -C "$directory" config user.name T
  git -C "$directory" config commit.gpgsign false
  printf '%s' "$directory"
}

write_agent_file() {
  local repo="$1" name="$2" content="$3"
  printf '%s' "$content" > "$repo/.claude/agents/$name"
}

commit_fixture_repo() {
  local repo="$1"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m fixture
}

# fixture_verdict <label> <agent file> <content> <want status> [fragment...]:
# one case of a table. Builds a fixture tree holding the one agent file, runs
# the check, and fails naming the label when the status or any fragment of the
# report differs.
fixture_verdict() {
  local label="$1" agent="$2" content="$3" repo
  shift 3
  repo="$(make_fixture_repo "$label")"
  write_agent_file "$repo" "$agent" "$content"
  repo_verdict "$label" "$repo" "$@"
}

# repo_verdict <label> <repo> <want status> [fragment...]: the check half of
# fixture_verdict, for a row whose fixture holds a two-dot diff with no -z. The
# path-quoting lint reads such a literal as data only when the row hands it to
# write_agent_file directly, so that row writes its own fixture first.
repo_verdict() {
  local label="$1" repo="$2" want_status="$3" fragment
  shift 3
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq "$want_status" ] || { echo "$label: status $status, want $want_status"; return 1; }
  for fragment in "$@"; do
    grep -qF -- "$fragment" <<<"$output" || { echo "$label: report lacks '$fragment'"; return 1; }
  done
  return 0
}

BARE_COUNT="review bases derived by a bare merge-base against the default branch: "
UNNAMED_COUNT="agent files naming BASE_SHA without naming resolve-audit-base.sh: "
DIFF_COUNT="review diffs consuming a base that never reached the fork point: "

# ---------- fixture content ----------

CONVERTED_OK='Agent prose.
```bash
FULL_BASE=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null || true)
BASE_REF="$(cd "$AUDIT_ROOT" && .github/audit/resolve-audit-base.sh)"
BASE_SHA="$(git -C "$AUDIT_ROOT" merge-base "${BASE_REF}" HEAD 2>/dev/null || true)"
```
'

DRIFTED_BARE_MERGE_BASE='Agent prose.
```bash
BASE_SHA=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null || true)
```
The base comes from .github/audit/resolve-audit-base.sh, or so this file claims.
'

DRIFTED_LOWERCASE_ALIAS='Agent prose.
```bash
base=$(git merge-base HEAD "origin/main")
```
Derived per .github/audit/resolve-audit-base.sh.
'

NAMES_BASE_SHA_NO_RESOLVER='Pass the same `BASE_SHA` you already resolved at the start of the run.
'

UNRELATED_FILE='This agent never resolves a review base at all.
'

FULL_BASE_ONLY='```bash
FULL_BASE=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null || true)
```
'

# The same drift as DRIFTED_BARE_MERGE_BASE, in the NON-origin form the real
# FULL_BASE line already carries as its own fallback arm. A pattern keyed to
# `origin/` alone matches nothing here, so the drift goes uncounted while
# assertion 2 still passes (the prose does name the resolver) and the check
# reports a clean tree.
DRIFTED_BARE_MERGE_BASE_NO_ORIGIN='Agent prose.
```bash
BASE_SHA=$(git -C "$AUDIT_ROOT" merge-base HEAD "${default_branch}" 2>/dev/null || true)
```
The base comes from .github/audit/resolve-audit-base.sh, or so this file claims.
'

# The same drift again, naming the branch as a bare literal. This is the form
# that defeats enumerating bad shapes in the ERE: `main` occurs in ordinary
# English inside these files, so a pattern carrying it reds a correct tree.
# Only the positive BASE_REF rule catches this one.
DRIFTED_BARE_LITERAL_BRANCH='Agent prose.
```bash
BASE_SHA=$(git -C "$AUDIT_ROOT" merge-base HEAD main 2>/dev/null || true)
```
The base comes from .github/audit/resolve-audit-base.sh, or so this file claims.
'

# FULL_BASE owns the FIRST merge-base on the line and a drifted BASE_SHA owns
# the SECOND. An ownership rule reading only the first occurrence clears the
# whole line on FULL_BASE'"'"'s exemption and never sees the second call.
TWO_CALLS_ONE_LINE='Agent prose.
```bash
FULL_BASE=$(git merge-base HEAD "origin/${default_branch}") ; BASE_SHA=$(git merge-base HEAD "${default_branch}")
```
Derived per .github/audit/resolve-audit-base.sh.
'

# A drifted call sharing its LINE with a legitimate BASE_REF assignment. The
# BASE_REF exemption has to bind to a call's own argument list: a line-wide
# test clears this whole line on the mention alone, which is the same
# unsoundness TWO_CALLS_ONE_LINE pins for the FULL_BASE exemption.
DRIFT_BESIDE_BASE_REF='Agent prose.
```bash
BASE_REF="$(cd "$AUDIT_ROOT" && .github/audit/resolve-audit-base.sh)" ; BASE_SHA=$(git merge-base HEAD "origin/${default_branch}")
```
'

# The same escape via a trailing comment rather than a second command. The
# stop set is what keeps `# was BASE_REF` from vouching for the call.
DRIFT_WITH_BASE_REF_COMMENT='Agent prose.
```bash
BASE_SHA=$(git merge-base HEAD "origin/${default_branch}")  # was BASE_REF, simplified
```
The base comes from .github/audit/resolve-audit-base.sh, or so this file claims.
'

# A drifted call whose `$( )` has already CLOSED before BASE_REF appears.
# The stop set has to end the argument list at `)`, not just at a command or
# comment boundary: prose describing the retired form mentions BASE_REF after
# the call, and the file IS the instruction, so the line still reds.
DRIFT_BASE_REF_AFTER_CLOSE='Agent prose.
The retired form was BASE_SHA=$(git merge-base HEAD main), now BASE_REF.
'

# ---------- assertion 1: no bare-merge-base review derivation ----------

@test "fixture: a converted file (FULL_BASE plus a resolver-derived BASE_SHA) passes clean" {
  local repo
  repo="$(make_fixture_repo converted-ok)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$CONVERTED_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
  grep -qF "agent files naming BASE_SHA without naming resolve-audit-base.sh: 0" <<<"$output" || return 1
}

# bats test_tags=protected
@test "fixture: a BASE_SHA derived by a bare merge-base fails assertion 1" {
  # Assertion 2 is satisfied in the first row (the file does name the resolver),
  # so that red is assertion 1's alone: the two are independently reportable.
  fixture_verdict drifted-bare code-audit-maintainer-node.md "$DRIFTED_BARE_MERGE_BASE" 1 \
    code-audit-maintainer-node.md "${BARE_COUNT}1" "${UNNAMED_COUNT}0" || return 1
  fixture_verdict drifted-alias code-audit-maintainer-shell.md "$DRIFTED_LOWERCASE_ALIAS" 1 "${BARE_COUNT}1" || return 1
  fixture_verdict drifted-bare-no-origin code-audit-maintainer-node.md "$DRIFTED_BARE_MERGE_BASE_NO_ORIGIN" 1 \
    code-audit-maintainer-node.md "${BARE_COUNT}1" || return 1
  fixture_verdict two-calls-one-line code-audit-maintainer-shell.md "$TWO_CALLS_ONE_LINE" 1 "${BARE_COUNT}1" || return 1
  fixture_verdict drifted-bare-literal code-audit-maintainer-shell.md "$DRIFTED_BARE_LITERAL_BRANCH" 1 "${BARE_COUNT}1" || return 1
  fixture_verdict drift-beside-base-ref code-audit-maintainer-node.md "$DRIFT_BESIDE_BASE_REF" 1 "${BARE_COUNT}1" || return 1
  fixture_verdict drift-base-ref-comment code-audit-maintainer-shell.md "$DRIFT_WITH_BASE_REF_COMMENT" 1 "${BARE_COUNT}1" || return 1
  fixture_verdict drift-base-ref-after-close code-audit-github-workflows.md "$DRIFT_BASE_REF_AFTER_CLOSE" 1 "${BARE_COUNT}1"
}
@test "assertion 1: an exempt derivation is never counted (FULL_BASE self-skip, KEY_BASE through KEY_REF, ELIG_BASE eligibility)" {
  fixture_verdict full-base-only code-audit-github-workflows.md "$FULL_BASE_ONLY" 0 "${BARE_COUNT}0" || return 1
  fixture_verdict key-base-derived-ok code-audit-frontend.md "$KEY_BASE_DERIVED_OK" 0 "${BARE_COUNT}0" || return 1
  fixture_verdict elig-base-derived-ok code-audit-frontend.md "$ELIG_BASE_DERIVED_OK" 0 "${BARE_COUNT}0" "${DIFF_COUNT}0"
}
# KEY_BASE joins FULL_BASE in the by-name exemption (contract F). Its call
# passes KEY_REF rather than BASE_REF, so the positive BASE_REF rule cannot
# exempt it on its own; only the by-name check can, and only for the exact
# name, not a lookalike.
KEY_BASE_DERIVED_OK='Agent prose.
```bash
BASE_REF="$(cd "$AUDIT_ROOT" && .github/audit/resolve-audit-base.sh)"
BASE_SHA="$(git -C "$AUDIT_ROOT" merge-base "${BASE_REF}" HEAD 2>/dev/null || true)"
KEY_REF="$BASE_REF"
KEY_BASE="$(git -C "$AUDIT_ROOT" merge-base "${KEY_REF}" HEAD 2>/dev/null || true)"
```
'

# A variable that merely resembles KEY_BASE. The exemption is by name, so this
# must still fail: widening it to "anything that looks like a key base" would
# reopen the hole the by-name rule exists to close.
SOME_OTHER_BARE_MERGE_BASE='Agent prose.
```bash
SOME_OTHER=$(git merge-base HEAD main)
```
Derived per .github/audit/resolve-audit-base.sh.
'

@test "assertion 1: a lookalike name is not exempt (a variable resembling KEY_BASE, a name ending in ELIG_BASE)" {
  fixture_verdict some-other-bare code-audit-maintainer-node.md "$SOME_OTHER_BARE_MERGE_BASE" 1 "${BARE_COUNT}1" || return 1
  fixture_verdict not-elig-base code-audit-frontend.md "$NOT_ELIG_BASE_BARE" 1 "${BARE_COUNT}1"
}
# ELIG_BASE joins FULL_BASE and KEY_BASE in the by-name exemption. It is the
# default member's waive-eligibility fork point, merge-based against the branch
# the pull request merges into, and it is never a review base; its call passes
# no BASE_REF, so only the name can admit it.
ELIG_BASE_DERIVED_OK='```bash
ELIG_BASE="$(git -C "$root" merge-base HEAD "$primary_reference" 2>/dev/null || git -C "$root" merge-base HEAD "$fallback_reference" 2>/dev/null || true)"
if ! git -C "$root" diff --name-only -z "${ELIG_BASE}...HEAD" > "$tmp/elig"; then
```
'

# The same eligibility diff in the two-dot form: ELIG_BASE is a base
# spelling assertion 3 must recognise, or a drift on it goes unseen.
DIFF_ELIG_BASE_TWO_DOT_NO_Z='```bash
if ! git -C "$root" diff --name-only "${ELIG_BASE}" > "$tmp/elig"; then
```
'

# A name that merely ends in ELIG_BASE is not the exempt name.
NOT_ELIG_BASE_BARE='```bash
MY_ELIG_BASE="$(git -C "$root" merge-base HEAD main)"
```
'

@test "assertion 3: an unanchored or two-dot diff fails (ELIG_BASE, the resolver piped in, BASE_REF direct, two-dot on BASE_SHA, in a code span, before a later three-dot call, before a semicolon and a later range, FULL_BASE self-skip)" {
  local repo
  repo="$(make_fixture_repo diff-elig-base-two-dot)"
  write_agent_file "$repo" code-audit-frontend.md "$DIFF_ELIG_BASE_TWO_DOT_NO_Z"
  repo_verdict diff-elig-base-two-dot "$repo" 1 "${DIFF_COUNT}1" || return 1
  # Assertions 1 and 2 are both satisfied here, so this red is assertion 3's alone.
  fixture_verdict diff-resolver-direct code-audit-frontend.md "$DIFF_RESOLVER_DIRECT" 1 \
    code-audit-frontend.md "${DIFF_COUNT}1" "${BARE_COUNT}0" "${UNNAMED_COUNT}0" || return 1
  fixture_verdict diff-base-ref-direct code-audit-maintainer-node.md "$DIFF_BASE_REF_DIRECT" 1 "${DIFF_COUNT}1" || return 1
  fixture_verdict diff-base-sha-two-dot code-audit-frontend.md "$DIFF_BASE_SHA_TWO_DOT" 1 "${DIFF_COUNT}1" || return 1
  fixture_verdict diff-base-sha-two-dot-span code-audit-frontend.md "$DIFF_BASE_SHA_TWO_DOT_SPAN" 1 "${DIFF_COUNT}1" || return 1
  fixture_verdict diff-two-calls-one-line code-audit-maintainer-shell.md "$TWO_DIFFS_ONE_LINE" 1 "${DIFF_COUNT}1" || return 1
  fixture_verdict diff-semicolon-later-range code-audit-maintainer-shell.md "$DIFF_SEMICOLON_LATER_RANGE" 1 \
    code-audit-maintainer-shell.md "${DIFF_COUNT}1" || return 1
  # Assertion 1 still exempts the FULL_BASE derivation itself; the two
  # assertions decide independently about the same variable.
  fixture_verdict diff-full-base-two-dot code-audit-maintainer-shell.md "$DIFF_FULL_BASE_TWO_DOT" 1 "${DIFF_COUNT}1" "${BARE_COUNT}0"
}
# ---------- assertion 2: every BASE_SHA namer names the resolver ----------

@test "assertion 2: a file naming BASE_SHA without the resolver fails; one never naming BASE_SHA passes" {
  # Assertion 1 stays clean in the first row, because dropping the reference
  # removes a line rather than adding a bad one: the case assertion 1 cannot
  # see, which is why both run.
  fixture_verdict names-base-no-resolver some-agent.md "$NAMES_BASE_SHA_NO_RESOLVER" 1 \
    "names BASE_SHA but never names resolve-audit-base.sh: .claude/agents/some-agent.md" "${UNNAMED_COUNT}1" "${BARE_COUNT}0" || return 1
  fixture_verdict unrelated unrelated.md "$UNRELATED_FILE" 0 "${UNNAMED_COUNT}0"
}
@test "fixture: multiple violations across files are all named, and the check still fails once" {
  local repo
  repo="$(make_fixture_repo multi)"
  write_agent_file "$repo" code-audit-maintainer-node.md "$DRIFTED_BARE_MERGE_BASE"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$NAMES_BASE_SHA_NO_RESOLVER"
  write_agent_file "$repo" unrelated.md "$UNRELATED_FILE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "code-audit-maintainer-node.md" <<<"$output" || return 1
  grep -qF "code-audit-maintainer-shell.md" <<<"$output" || return 1
  grep -qF "unrelated.md" <<<"$output" && return 1
  return 0
}

# ---------- assertion 3: no diff consumes an un-anchored base ----------
#
# Assertions 1 and 2 police how the base is DERIVED. This one polices what is
# then handed to `git diff`, an independent failure: a file can derive
# BASE_SHA correctly and scope its review off the raw ref one line later.

DIFF_ANCHORED_OK='Agent prose.
```bash
BASE_REF="$(cd "$AUDIT_ROOT" && .github/audit/resolve-audit-base.sh)"
BASE_SHA="$(git -C "$AUDIT_ROOT" merge-base "${BASE_REF}" HEAD 2>/dev/null || true)"
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${BASE_SHA}...HEAD" 2>/dev/null || true)
```
'

# The resolver piped straight into the diff, with no merge-base between them.
# `resolve-audit-base.sh` can return a REF, so this scopes the review off a tip
# that may have advanced past the fork point.
DIFF_RESOLVER_DIRECT='Agent prose.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "$(cd "$AUDIT_ROOT" && .github/audit/resolve-audit-base.sh)")
```
'

# The same defect one variable removed: BASE_REF holds the resolver output, so
# consuming it directly is the identical un-anchored diff.
DIFF_BASE_REF_DIRECT='Agent prose.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "$BASE_REF")
```
'

# The three-dot requirement binds the CORRECT variable too. A two-dot diff on
# BASE_SHA compares the base to the working tree exactly as one on BASE_REF
# does, so keying the rule to the raw-base spellings alone would let the
# likelier drift through: the member names the right value and still reviews
# the wrong thing.
DIFF_BASE_SHA_TWO_DOT='Agent prose, per .github/audit/resolve-audit-base.sh.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${BASE_SHA}" -- "*.ts")
```
'

# The same two-dot defect written as a markdown code span rather than a fence,
# which is how a definition restates its scope in prose. A restatement that
# drifts from the fence is still an instruction a model can follow.
DIFF_BASE_SHA_TWO_DOT_SPAN='The set is the exact `git -C "$AUDIT_ROOT" diff --name-only -z "${BASE_SHA}" -- "*.ts"` list the audit resolved, per .github/audit/resolve-audit-base.sh.
'

# A three-dot range on BASE_REF narrows correctly, since git resolves the merge
# base inside `...`. This assertion is about the range, not about which
# spelling reached it, so this passes.
DIFF_BASE_REF_THREE_DOT_OK='Agent prose.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${BASE_REF}...HEAD")
```
'

# A correct call whose trailing comment happens to name BASE_REF. The `...`
# already precedes the token here, so this passes on the range test alone; the
# two fixtures below are the ones that isolate the walls.
DIFF_TRAILING_COMMENT_OK='Agent prose.
```bash
BASE_REF="$(cd "$AUDIT_ROOT" && .github/audit/resolve-audit-base.sh)"
BASE_SHA="$(git -C "$AUDIT_ROOT" merge-base "${BASE_REF}" HEAD 2>/dev/null || true)"
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${BASE_SHA}...HEAD")   # never BASE_REF here
```
'

# Ordinary prose naming the command and a base in one sentence, which
# .claude/agents/worthiness-evaluator.md really does. No target token follows
# at all, so this passes without either wall.
DIFF_PROSE_MENTION_OK='This agent takes its file list from the orchestrator (or resolves it from `git diff --name-only` against the audit base).
'

# The backtick wall, isolated. The code span CLOSES and the surrounding
# sentence then names BASE_REF, with no `...` anywhere on the line, so the
# range test cannot exempt it and only the wall can. Remove the wall and this
# reads as a raw-base diff, condemning a line that runs no diff at all.
DIFF_SPAN_CLOSES_BEFORE_TARGET_OK='Run `git diff --name-only` yourself only when the orchestrator supplied no list; otherwise the value you want is already in BASE_REF.
'

# The `#` wall, isolated. A legitimate two-dot call on an unrelated revset
# (the staged index), with a trailing comment naming BASE_REF and no `...` on
# the line. Same shape as above on the shell side.
DIFF_TRAILING_COMMENT_NO_RANGE_OK='Agent prose.
```bash
staged=$(git -C "$AUDIT_ROOT" diff --name-only --cached)   # not BASE_REF, deliberately
```
'

# A two-dot call sharing its LINE with a correct three-dot one. The window has
# to end at the NEXT call, or the later call's `...` satisfies the range test
# for the earlier one and the bad call escapes. Bad call FIRST is the ordering
# that requires the wall; the reverse is caught by the walk alone.
TWO_DIFFS_ONE_LINE='Agent prose, per .github/audit/resolve-audit-base.sh.
```bash
changed=$(git diff --name-only -z "$BASE_SHA") ; full_changed=$(git diff --name-only -z "${FULL_BASE}...HEAD")
```
'

# A `;`-joined line whose trailing command is not a diff call at all and
# carries a `...` of its own. None of the other three walls closes the leading
# call: there is no second `diff --name-only`, no `#`, and no backtick. Without
# a `;` wall the window runs to end of line and the LATER command's range
# vouches for a two-dot call, so the check reports 0 in exactly the case it
# exists to catch. The fixture above needs the call wall; this one needs the
# `;` wall and nothing else can save it.
DIFF_SEMICOLON_LATER_RANGE='Agent prose, per .github/audit/resolve-audit-base.sh.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "$BASE_SHA") ; echo "${BASE_REF}...HEAD"
```
'

# The self-skip diff, correctly ranged.
DIFF_FULL_BASE_OK='Agent prose.
```bash
FULL_BASE=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null || true)
full_changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${FULL_BASE}...HEAD" 2>/dev/null || true)
```
'

# The self-skip diff gone two-dot. FULL_BASE is exempt from assertion 1 (it is
# the legitimate bare merge-base) but nothing exempts it here: a working-tree
# comparison decides membership as wrongly as it decides review scope, and a
# member that self-skips on a bad list writes no marker the gate still demands.
DIFF_FULL_BASE_TWO_DOT='Agent prose.
```bash
FULL_BASE=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null || true)
full_changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${FULL_BASE}" 2>/dev/null || true)
```
'

@test "assertion 3: a correctly anchored diff passes (resolver-derived BASE_SHA, three-dot on BASE_REF, comment or prose naming a base, a non-roster agent, FULL_BASE self-skip)" {
  fixture_verdict diff-anchored-ok code-audit-maintainer-shell.md "$DIFF_ANCHORED_OK" 0 "${DIFF_COUNT}0" || return 1
  fixture_verdict diff-base-ref-three-dot code-audit-maintainer-node.md "$DIFF_BASE_REF_THREE_DOT_OK" 0 "${DIFF_COUNT}0" || return 1
  fixture_verdict diff-trailing-comment code-audit-maintainer-shell.md "$DIFF_TRAILING_COMMENT_OK" 0 "${DIFF_COUNT}0" || return 1
  fixture_verdict diff-prose-mention code-audit-maintainer-shell.md "$DIFF_PROSE_MENTION_OK" 0 "${DIFF_COUNT}0" || return 1
  fixture_verdict diff-span-closes code-audit-maintainer-node.md "$DIFF_SPAN_CLOSES_BEFORE_TARGET_OK" 0 "${DIFF_COUNT}0" || return 1
  local repo
  repo="$(make_fixture_repo diff-comment-no-range)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$DIFF_TRAILING_COMMENT_NO_RANGE_OK"
  repo_verdict diff-comment-no-range "$repo" 0 "${DIFF_COUNT}0" || return 1
  # An agent that takes its file list from the orchestrator has no review base,
  # so it is outside this assertion's claim. The scan pathspec is narrower than
  # assertions 1 and 2's, which is easy to widen back by accident.
  fixture_verdict diff-non-roster-agent worthiness-evaluator.md "$DIFF_BASE_SHA_TWO_DOT" 0 "${DIFF_COUNT}0" || return 1
  fixture_verdict diff-full-base code-audit-maintainer-shell.md "$DIFF_FULL_BASE_OK" 0 "${DIFF_COUNT}0"
}
# ---------- the resolver script is part of the scan surface ----------
#
# Each fixture copies the REAL resolver into the fixture tree and breaks one
# construct in it with a substitution that must take, so these prove the
# widened pathspec reaches the script: a check still reading the definitions
# alone stays green on every one of them.

# copy_resolver <repo>: the real resolver at its real path in <repo>.
# shellcheck disable=SC2329 # called from @test bodies, which shellcheck does not see
copy_resolver() {
  mkdir -p "$1/.gaia/scripts"
  cp "$REPO_ROOT/.gaia/scripts/audit-resolve-scope.sh" "$1/.gaia/scripts/audit-resolve-scope.sh"
}

# mutate_resolver <repo> <perl-substitution> <needle-after>: applies the
# substitution and fails the test unless <needle-after> is then present, so
# a substitution that silently matched nothing cannot pass as red evidence.
# shellcheck disable=SC2329 # called from @test bodies, which shellcheck does not see
mutate_resolver() {
  local file="$1/.gaia/scripts/audit-resolve-scope.sh"
  perl -pi -e "$2" "$file"
  grep -qF -- "$3" "$file" || {
    echo "the mutation did not take; this test proves nothing" >&2
    return 1
  }
}

@test "resolver: the real resolver script passes all three assertions" {
  local repo
  repo="$(make_fixture_repo resolver-ok)"
  copy_resolver "$repo"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
}

@test "resolver: a script deviating on assertion 1, 2 or 3 fails" {
  local repo
  repo="$(make_fixture_repo resolver-bare)"
  copy_resolver "$repo"
  mutate_resolver "$repo" 's/merge-base "\$BASE_REF" HEAD/merge-base HEAD "origin\/main"/' 'BASE_SHA="$(git -C "$root" merge-base HEAD "origin/main"'
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ] || { echo "assertion 1: status $status"; return 1; }
  grep -qF "${BARE_COUNT}1" <<<"$output" || { echo "assertion 1: $output"; return 1; }
  grep -qF ".gaia/scripts/audit-resolve-scope.sh:" <<<"$output" || { echo "assertion 1: $output"; return 1; }

  repo="$(make_fixture_repo resolver-unnamed)"
  copy_resolver "$repo"
  mutate_resolver "$repo" 's/resolve-audit-base\.sh/resolve-base-elsewhere.sh/g' 'resolve-base-elsewhere.sh'
  grep -qF 'resolve-audit-base.sh' "$repo/.gaia/scripts/audit-resolve-scope.sh" && return 1
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ] || { echo "assertion 2: status $status"; return 1; }
  grep -qF "names BASE_SHA but never names resolve-audit-base.sh: .gaia/scripts/audit-resolve-scope.sh" <<<"$output" || { echo "assertion 2: $output"; return 1; }

  repo="$(make_fixture_repo resolver-two-dot)"
  copy_resolver "$repo"
  mutate_resolver "$repo" 's/"\$\{SIDE_BASE\}\.\.\.\$\{side_commit\}"/"\${SIDE_BASE}"/' 'diff --name-only -z --no-renames "${SIDE_BASE}" --'
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ] || { echo "assertion 3: status $status"; return 1; }
  grep -qF "${DIFF_COUNT}1" <<<"$output" || { echo "assertion 3: $output"; return 1; }
  grep -qF ".gaia/scripts/audit-resolve-scope.sh:" <<<"$output" || { echo "assertion 3: $output"; return 1; }
}
# ---------- real repo: the standing guarantee ----------

# bats test_tags=whole-tree
@test "real repo: every Code Audit Team definition resolves its review base through the resolver" {
  run gaia_check_audit_base_derivation "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
  grep -qF "agent files naming BASE_SHA without naming resolve-audit-base.sh: 0" <<<"$output" || return 1
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
}

# bats test_tags=whole-tree
@test "real repo: every changed-file diff in the roster is a three-dot range" {
  # Assertion 3 states the rule negatively (a count of violations), so this
  # pins the positive form directly: every `diff --name-only` the five
  # definitions carry inside a fence resolves a three-dot range (`<something>...HEAD`, or the resolver's per-side `${...}...${...}` pathspec listing). A
  # definition that drops to two-dot reds here as well as on the check.
  #
  # The `"?` accepts both spellings of the assignment. Requiring `$(` to sit
  # immediately after the `=` matches the unquoted form alone, so a definition
  # normalized to `changed="$(git ...)"` drops out of the net entirely.
  # The net reads the definitions AND the resolver script, where the
  # specialists' diffs live: the script writes each diff to a file under an
  # exit-status test (`if ! git ... diff ... > file`, or its `elif` arm), so that
  # spelling joins the assignment one, and an indented assignment counts as much
  # as a column-0 one.
  run git -C "$REPO_ROOT" grep -hIE '^[[:space:]]*[a-z_]+="?\$\(git .*diff --name-only|^[[:space:]]*(el)?if ! git .*diff --name-only' -- '.claude/agents/' '.gaia/scripts/audit-resolve-scope.sh'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Pin the breadth, not just non-emptiness. `[ -n "$output" ]` is satisfied by
  # any ONE surviving line, so a net that quietly stops covering most of the
  # roster still passes it and the shrink is reported nowhere. A roster change
  # that moves this number is a deliberate update to the number, never a reason
  # to relax the assertion back to non-emptiness.
  # The pin and the message it prints read ONE constant, so an update to the
  # number cannot leave the failure text claiming a different expectation.
  expected_lines=3
  net_lines="$(grep -c . <<<"$output")"
  [ "$net_lines" -eq "$expected_lines" ] || {
    printf 'roster diff-line net covered %s lines, expected %s\n' \
      "$net_lines" "$expected_lines"
    return 1
  }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qE '\.\.\.(HEAD|\$\{[A-Za-z_]+\})' <<<"$line" || {
      printf 'changed-file diff is not a three-dot range: %s\n' "$line"
      return 1
    }
  done <<< "$output"
}

# bats test_tags=whole-tree
@test "real repo: the guarantee above is not vacuous -- the scan surface names BASE_SHA and keeps an exempt whole-PR base" {
  # Both verdicts are counts of violations, so a scan that saw no candidate
  # at all reports zero and passes. Pin both candidate sets as non-empty: the
  # BASE_SHA namers assertion 2 ranges over, and the exempted whole-PR
  # derivations assertion 1 must be deciding about rather than never meeting.
  run git -C "$REPO_ROOT" grep -lIF 'BASE_SHA' -- '.claude/agents/' '.gaia/scripts/audit-resolve-scope.sh'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  grep -qF "code-audit-frontend.md" <<<"$output" || return 1
  grep -qF ".gaia/scripts/audit-resolve-scope.sh" <<<"$output" || return 1

  # The default member's eligibility fork point is a bare merge-base the
  # resolver owns under the exempt name ELIG_BASE.
  run git -C "$REPO_ROOT" grep -lIE '^[[:space:]]*ELIG_BASE="?\$\(git -C "\$root" merge-base ' -- '.gaia/scripts/audit-resolve-scope.sh'
  [ "$status" -eq 0 ]
  grep -qF ".gaia/scripts/audit-resolve-scope.sh" <<<"$output" || return 1

  # The resolver takes its membership FULL_BASE from the shared
  # base-provenance resolver rather than a bare merge-base, so the by-name
  # exemption it still exercises is KEY_BASE's. Pin that candidate the same
  # way, so assertion 1 is shown deciding about the script rather than never
  # meeting a merge-base in it.
  run git -C "$REPO_ROOT" grep -lIE '^[[:space:]]*\[ -z "\$KEY_REF" \] \|\| KEY_BASE="\$\(git -C "\$root" merge-base ' -- '.gaia/scripts/audit-resolve-scope.sh'
  [ "$status" -eq 0 ]
  grep -qF ".gaia/scripts/audit-resolve-scope.sh" <<<"$output" || return 1
}

# ---------- structural ----------

@test "a bad repo_root reports 2, never a clean 0 (not a repository, a subdirectory, a bare repository, a .git directory)" {
  local outside="$BATS_TEST_TMPDIR/not-a-repo" bare="$BATS_TEST_TMPDIR/bare.git" live
  mkdir -p "$outside"
  run gaia_check_audit_base_derivation "$outside"
  # 2, not 1: "the check could not run" is a different answer from "the check
  # says no", and neither is the 0 an unscanned tree used to report.
  [ "$status" -eq 2 ] || { echo "not a repository: status $status"; return 1; }
  grep -qF "is not a git repository root; nothing was scanned" <<<"$output" || { echo "not a repository: $output"; return 1; }
  grep -qF "${BARE_COUNT}0" <<<"$output" && {
    echo "printed a clean verdict for a tree it never scanned" >&2
    return 1
  }

  # --git-dir alone succeeds from anywhere inside a repo, so this is the case
  # that separates "is in a repo" from "is a repo root".
  run gaia_check_audit_base_derivation "$REPO_ROOT/.gaia/scripts"
  [ "$status" -eq 2 ] || { echo "subdirectory: status $status"; return 1; }
  grep -qF "is not a git repository root; nothing was scanned" <<<"$output" || { echo "subdirectory: $output"; return 1; }

  # --show-prefix alone clears both a bare repository and a .git directory
  # (exit 0, empty output); the work-tree check is what separates them.
  git init -q --bare "$bare"
  run gaia_check_audit_base_derivation "$bare"
  [ "$status" -eq 2 ] || { echo "bare repository: status $status"; return 1; }
  live="$(make_fixture_repo gitdir-probe)"
  write_agent_file "$live" some-agent.md "$UNRELATED_FILE"
  commit_fixture_repo "$live"
  run gaia_check_audit_base_derivation "$live/.git"
  [ "$status" -eq 2 ] || { echo ".git directory: status $status"; return 1; }
  grep -qF "is not a git repository root; nothing was scanned" <<<"$output" || { echo ".git directory: $output"; return 1; }
}
@test "structural: check-audit-base-derivation.sh is executable" {
  [ -x "$CHECK" ]
}

@test "structural: sourcing the script defines gaia_check_audit_base_derivation with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_audit_base_derivation >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "structural: never invokes cd, per .claude/rules/shell-cwd.md" {
  code_lines="$(grep -vE '^[[:space:]]*#' "$CHECK")"
  grep -qE '(^|[^[:alnum:]_])cd([^[:alnum:]_]|$)' <<<"$code_lines" && return 1
  return 0
}

@test "structural: no hardcoded /Users or /home paths" {
  grep -E '/Users/|/home/' "$CHECK" && return 1
  return 0
}

