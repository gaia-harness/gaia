#!/usr/bin/env bats
# Structural, regression, and invariant tests for the shared ownership
# classifier (UAT-015), covering the parts owned by the ownership-classifier
# phase: exactly-one-classifier (part 1), every-consumer-sources-it
# (part 2), the remaining in-scope sets staying separately named plus the
# retired auditable-base literal's pins (part 3), the golden behavior table
# (part 4), and absent-module -> DENY (part 5). Plus one further invariant:
# SEC-007 (every machinery path is roster-claimed).
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/audit-roster.sh"
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  SCOPE_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
  MACHINERY_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  PROVENANCE_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-base-provenance.sh"
  RESOLVER="$REPO_ROOT/.gaia/scripts/resolve-audit-members.sh"
  HOOK="$REPO_ROOT/.claude/hooks/pr-merge-audit-check.sh"
  # The gate's whole text, the hook and its siblings, for the structural reads.
  . "$THIS_DIRECTORY/helpers/merge-gate-text.sh"
  HOOK_TEXT="$BATS_TEST_TMPDIR/merge-gate-text.sh"
  merge_gate_text "$HOOK" > "$HOOK_TEXT"
  # One entry per arm of the allowlist, not just the first. The uniqueness
  # invariant below is what stops a second copy of this set appearing in another
  # tracked script and drifting from this one, and an arm it does not name is an
  # arm that may be copied freely.
  ALLOWLIST_LITERAL='wiki/*|.claude/*|.gaia/*|docs/*'
}

# Count real invocations of a symbol in a file. A presence probe -- `type X` or
# `command -v X`, the shape a consumer uses to decide whether a guarded load
# actually defined the symbol -- names it without calling it, so it is excluded.
# The count assertions below are about invocations, and a bare grep for the name
# reads a degrade guard as a second call.
#
# The probe is stripped from the line rather than dropping the line, and counted
# per occurrence rather than per line, so `type X >/dev/null && X "$arg"` still
# counts the call it carries. Dropping the whole line reads that one-liner as
# zero invocations, which greens the "calls it once" assertion over a consumer
# that calls it twice.
#
# Counting occurrences is what makes the two other filters load-bearing, and
# per-line counting hid the need for both: comments go first, because a header
# naming the symbol twice in prose now contributes two, and the match is
# bounded by a non-identifier at BOTH ends, because `audit_scope_init` is a
# prefix of any longer name someone adds later, and because a terminator that
# demands whitespace declines every other one a real second call can carry --
# `audit_scope_init;`, a bare call at end of line -- which greens the
# calls-it-once pin over exactly the drift it exists to catch.
#
# Counted by splitting on the boundaries rather than by matching across them:
# `grep -o` CONSUMES the boundary character it matched and resumes after it, so
# two occurrences separated by exactly one non-identifier character -- the
# `audit_scope_init;audit_scope_init` spelling -- leave the second with no
# boundary left and it goes uncounted, which is the same green-over-drift the
# widened terminator was meant to end.
count_invocations() {
  sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' "$1" \
    | sed -E "s/(^|[[:space:]])(type|command -v)[[:space:]]+$2([[:space:]]|\$)/\1 /g" \
    | awk -v sym="$2" '
        { gsub(/[^A-Za-z0-9_]/, " ")
          n = split($0, w, " ")
          for (i = 1; i <= n; i++) if (w[i] == sym) c++ }
        END { print c + 0 }
      '
}

# Extract a named function's body (from its `name() {` line through the next
# column-0 `}`) so a structural assertion can inspect one function in
# isolation without matching a sibling's text.
extract_function() {
  local file="$1" name="$2"
  awk -v name="$name" '
    $0 ~ "^" name "\\(\\) \\{" { capture = 1 }
    capture { print }
    capture && /^}/ { exit }
  ' "$file"
}

# ---------------------------------------------------------------------------
# Part 1: exactly one classifier. The merge gate's out-of-scope allowlist
# case-arm literal lives in exactly one tracked file.
# ---------------------------------------------------------------------------

# bats test_tags=whole-tree
@test "exactly one classifier: every out-of-scope allowlist arm lives in one tracked file" {
  while IFS= read -r lit; do
    [ -n "$lit" ] || continue
    # -z and a NUL read: a carrier whose path holds a non-ASCII byte would
    # otherwise arrive C-quoted and fail the exact-path assertion below under a
    # name no file on disk has. Command substitution discards NUL bytes, so the
    # records are accumulated in the loop instead of captured from one.
    matches=""
    while IFS= read -r -d '' matched_file; do
      matches="${matches}${matched_file}
"
    done < <(git -C "$REPO_ROOT" grep -lF -z -- "$lit" -- '*.sh')
    count="$(printf '%s' "$matches" | grep -c .)"
    [ "$count" -eq 1 ] || return 1
    grep -qxF ".claude/hooks/lib/audit-scope.sh" <<<"$matches" || return 1
  done <<EOF
$ALLOWLIST_LITERAL
EOF
}

# ---------------------------------------------------------------------------
# Part 2: every consumer sources the module and calls audit_scope_init once
# per run, never once per path.
# ---------------------------------------------------------------------------

@test "surfaces exist: the classifier, the machinery list, and every consumer" {
  [ -f "$SCOPE_LIBRARY" ]
  [ -f "$MACHINERY_LIBRARY" ]
  [ -f "$RESOLVER" ]
  [ -f "$HOOK" ]
}

@test "resolve-audit-members.sh sources audit-scope.sh and calls audit_scope_init once" {
  grep -qF -- "audit-scope.sh" "$RESOLVER" || return 1
  count="$(count_invocations "$RESOLVER" audit_scope_init)"
  [ "$count" -eq 1 ]
}

# last_definition <file>: the name of the last function the file defines at top
# level, in either spelling bash accepts (`name()` and `function name`, the
# `()` optional after the keyword) and with the opening brace on the definition
# line or on the line below it. Reading only the canonical `name() {` would
# leave the pin below green when a function is appended as `function name {` or
# with extra spacing, which is the drift it exists to catch: `tail -1` would
# still return the previously-last definition.
#
# The boundary, stated rather than implied, because the pin is only as honest
# as this matcher: a definition that does not start at column 1 is out of
# reach. Both modules define at top level and neither has a reason not to, so
# an indented definition would be a larger change than the append this pin
# watches for; reaching it needs a parser rather than a line matcher, and a
# line matcher that claimed it would be the same over-claim this helper was
# repaired for.
last_definition() {
  sed -E -n \
    -e 's/^function[[:space:]]+([A-Za-z0-9_]+)[[:space:]]*(\(\)[[:space:]]*)?\{.*$/\1/p' \
    -e 's/^([A-Za-z0-9_]+)[[:space:]]*\([[:space:]]*\)[[:space:]]*\{.*$/\1/p' \
    -e 's/^function[[:space:]]+([A-Za-z0-9_]+)[[:space:]]*(\(\)[[:space:]]*)?$/\1/p' \
    -e 's/^([A-Za-z0-9_]+)[[:space:]]*\([[:space:]]*\)[[:space:]]*$/\1/p' \
    "$1" | tail -1
}

# The resolver argues that probing each module's LAST definition needs no
# reasoning about which internal call goes how deep: a truncated copy parses as
# far as the truncation and defines everything ahead of it, so an early-export
# probe answers yes for a copy missing what the call it gates will reach. That
# argument is a property of two other files, and appending a function to either
# silently demotes the probe to the early-export kind the argument rules out.
@test "each module probe in resolve-audit-members.sh names its module's last definition" {
  probed_scope="$(grep -oE '^type [A-Za-z0-9_]+' "$RESOLVER" | awk 'NR==1 {print $2}')"
  probed_prov="$(grep -oE '^type [A-Za-z0-9_]+' "$RESOLVER" | awk 'NR==2 {print $2}')"
  [ -n "$probed_scope" ]
  [ -n "$probed_prov" ]

  last_scope="$(last_definition "$SCOPE_LIBRARY")"
  last_prov="$(last_definition "$PROVENANCE_LIBRARY")"
  [ -n "$last_scope" ]
  [ -n "$last_prov" ]

  [ "$probed_scope" = "$last_scope" ]
  [ "$probed_prov" = "$last_prov" ]
}

@test "pr-merge-audit-check.sh sources audit-scope.sh and audit-machinery.sh, and calls audit_scope_init once" {
  grep -qF -- "audit-scope.sh" "$HOOK_TEXT" || return 1
  grep -qF -- "audit-machinery.sh" "$HOOK_TEXT" || return 1
  count="$(count_invocations "$HOOK_TEXT" audit_scope_init)"
  [ "$count" -eq 1 ]
}

@test "no consumer calls the classifier once per path (no per-path source or init inside a changed-path loop)" {
  # A per-path fork would show the source/init call INSIDE the "while IFS= read"
  # dispatch loop bodies; those loops call only the batch predicate
  # (audit_owners_for_paths) or the single-path predicates directly, never
  # re-source or re-init. Grep each consumer's post-init body for a second
  # audit_scope_init call is already covered above (count -eq 1); this test
  # additionally proves the dispatch loop itself never calls it.
  for consumer_file in "$RESOLVER" "$HOOK_TEXT"; do
    dispatch_loop="$(awk '/while IFS= read -r path; do/,/^done/' "$consumer_file")"
    [ -z "$dispatch_loop" ] && continue
    grep -qF "audit_scope_init" <<<"$dispatch_loop" && return 1
  done
  true
}

# ---------------------------------------------------------------------------
# Part 3: the remaining in-scope sets stay separately named.
# audit_out_of_scope_allowlisted is the one path-classification predicate; the
# self-modification classifier it once had a sibling in is gone, along with
# the merge-gate bypass that was its only caller. CI's has_source stays
# a workflow-local grep pair, never replaced by a call into the module. No
# routing decision consults a hardcoded auditable-base literal: the function
# that once held one, audit_in_auditable_base, is gone, and ownership is a
# roster-declared two-tier precedence instead (claimant globs, then the
# default member's own declared globs).
# ---------------------------------------------------------------------------

@test "the out-of-scope allowlist is defined, and the self-modification classifier is gone from the library and the gate" {
  grep -qF "audit_out_of_scope_allowlisted() {" "$SCOPE_LIBRARY" || return 1
  grep -qF "audit_self_mod_classify" "$SCOPE_LIBRARY" && return 1
  grep -qE "audit_self_mod_classify|check_self_mod_only_update_pr|self_mod_only" "$HOOK_TEXT" && return 1
  true
}

@test "no routing decision consults a hardcoded auditable-base literal, and the symbol is gone" {
  body="$(extract_function "$SCOPE_LIBRARY" _audit_scope_owner_of)"
  [ -n "$body" ] || return 1
  grep -qF "audit_in_auditable_base" <<<"$body" && return 1
  grep -qF "audit_in_auditable_base" "$SCOPE_LIBRARY" && return 1
  true
}

# ---------------------------------------------------------------------------
# UAT-015: a claimant beats an overlapping default glob regardless of roster
# order. A fabricated two-member fixture declares a claimant glob
# (app/special/**) that is a strict subset of the default's own declared glob
# (app/**), so a path under app/special/ matches both. Written in both roster
# orders (default first, default last) to prove the precedence is structural
# (claimant tier is exhausted before the default tier is ever consulted),
# never an accident of which entry the roster lists first.
# ---------------------------------------------------------------------------

@test "UAT-015: claimant wins over an overlapping default glob in either roster order" {
  ROOT_DEFAULT_FIRST=$(mktemp -d -t audit-scope-order-a-XXXXXX)
  mkdir -p "$ROOT_DEFAULT_FIRST/.gaia"
  cat > "$ROOT_DEFAULT_FIRST/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-example
    globs:
      - "app/**"
    audience: adopter
    default: true
  - name: code-audit-claimant
    globs:
      - "app/special/**"
    audience: adopter
YAML

  ROOT_DEFAULT_LAST=$(mktemp -d -t audit-scope-order-b-XXXXXX)
  mkdir -p "$ROOT_DEFAULT_LAST/.gaia"
  cat > "$ROOT_DEFAULT_LAST/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-claimant
    globs:
      - "app/special/**"
    audience: adopter
  - name: code-audit-example
    globs:
      - "app/**"
    audience: adopter
    default: true
YAML

  run bash -c '
    . "$1"
    audit_scope_init "$2"
    audit_owner_for_path "app/special/x.ts"
    audit_scope_init "$3"
    audit_owner_for_path "app/special/x.ts"
  ' _ "$SCOPE_LIBRARY" "$ROOT_DEFAULT_FIRST" "$ROOT_DEFAULT_LAST"

  rm -rf "$ROOT_DEFAULT_FIRST" "$ROOT_DEFAULT_LAST"

  [ "$status" -eq 0 ]
  expected="code-audit-claimant
code-audit-claimant"
  [ "$output" = "$expected" ]
}

# ---------------------------------------------------------------------------
# Part 4: the gate's decision is unchanged across a golden table of path
# sets. Each case drives the real merge-gate hook end to end (a sandbox on a
# `feature` branch off `main`, mirroring the sibling pr-merge-audit-check.bats
# fixture) and asserts allow/deny.
# ---------------------------------------------------------------------------

golden_setup() {
  GREPO=$(mktemp -d -t audit-scope-golden-XXXXXX)
  git -C "$GREPO" init --quiet --initial-branch=main
  git -C "$GREPO" config user.email "test@example.com"
  git -C "$GREPO" config user.name "Test"
  git -C "$GREPO" config commit.gpgsign false

  mkdir -p "$GREPO/.gaia"
  printf '1.4.0\n' > "$GREPO/.gaia/VERSION"
  echo "# readme" > "$GREPO/README.md"
  # Seed a bundled workflow template on the base (main), so a feature commit
  # can re-render it verbatim: the shape of pull request the removed
  # self-modification bypass used to clear, which the table pins as a deny.
  mkdir -p "$GREPO/.gaia/cli/templates/workflows"
  printf 'name: Code Review Audit\n' \
    > "$GREPO/.gaia/cli/templates/workflows/fixture-audit.yml.tmpl"
  seed_audit_roster "$GREPO"
  git -C "$GREPO" add .gaia/VERSION .gaia/audit-ci.yml README.md \
    .gaia/cli/templates/workflows/fixture-audit.yml.tmpl
  git -C "$GREPO" commit --quiet -m "init"
  git -C "$GREPO" checkout --quiet -b feature

  # The real hook (run by absolute path via $HOOK, never copied) delegates
  # dispatch to .gaia/scripts/resolve-audit-members.sh CWD-relatively, so the
  # golden table needs a real copy here too, mirroring the sibling
  # pr-merge-audit-check.bats fixture. That copy resolves its own libs
  # relative to ITSELF ($GREPO/.claude/hooks/lib/), so the sandbox needs its
  # own copy of the shared ownership classifier alongside it.
  mkdir -p "$GREPO/.gaia/scripts" "$GREPO/.claude/hooks/lib"
  cp "$RESOLVER" "$GREPO/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$GREPO/.gaia/scripts/resolve-audit-members.sh"
  cp "$SCOPE_LIBRARY" "$GREPO/.claude/hooks/lib/audit-scope.sh"
  cp "$MACHINERY_LIBRARY" "$GREPO/.claude/hooks/lib/audit-machinery.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-base-provenance.sh" "$GREPO/.claude/hooks/lib/audit-base-provenance.sh"

  # A gh that answers the gate's fork query (`--json isCrossRepository`) with
  # `false`, and the pull-request record read with a record naming the
  # sandbox's head and carrying a complete PR review section (the gate denies
  # an allow that has none), and fails everything else, so the table never
  # reaches the developer's own gh.
  GOLDEN_GH_BIN="$GREPO.bin"
  mkdir -p "$GOLDEN_GH_BIN"
  cat > "$GOLDEN_GH_BIN/gh" <<EOF
#!/usr/bin/env bash
golden_repository="$GREPO"
EOF
  cat >> "$GOLDEN_GH_BIN/gh" <<'EOF'
case "$*" in *isCrossRepository*) printf 'false\n'; exit 0 ;; esac
if [ "$1 ${2-}" = "pr view" ]; then
  jq -n --arg head "$(git -C "$golden_repository" rev-parse HEAD)" \
    '{title:"", baseRefName:"main", number:30, headRefOid:$head, headRefName:"feature", body:("<!-- gaia:pr-review:start -->\n## PR review\n\nReviewed head: " + $head + "\nNo findings.\n<!-- gaia:pr-review:end -->")}'
  exit 0
fi
exit 1
EOF
  chmod +x "$GOLDEN_GH_BIN/gh"
}

golden_teardown() {
  [ -n "${GREPO:-}" ] && rm -rf "$GREPO" "$GREPO.bin"
  true
}

golden_commit() {
  while [ "$#" -gt 0 ]; do
    local path="$1" content="$2"; shift 2
    mkdir -p "$GREPO/$(dirname "$path")"
    printf '%s\n' "$content" > "$GREPO/$path"
    git -C "$GREPO" add "$path"
  done
  git -C "$GREPO" commit --quiet -m "change"
}

# The command deliberately names NO pull request. Every arm that clears a merge
# off the current-branch record binds to the pull request the command names, and
# an absent positional is gh's current-branch default, so the binding holds by
# construction and this table keeps varying only the thing it is named for: the
# path set. Adding a number here would make each case turn on whether the
# sandbox can resolve a pull-request record, which it cannot and which is the
# sibling suite's subject, not this one's.
golden_run_hook() {
  local json
  json=$(jq -n '{tool_name: "Bash", tool_input: {command: "gh pr merge --squash"}}')
  PATH="$GOLDEN_GH_BIN:$PATH" invoke_hook_in "$GREPO" "$json" "$HOOK"
}

# Rows are decision | path | content [| path | content]. One sandbox serves
# every row: each row resets `feature` to `main` and empties the local store,
# so no row's commit or gate state reaches the next.
#
# The Makefile row's witness must be a root file in scope that no member's
# globs claim, or the table loses its ownerless-in-scope row entirely; a root
# `Dockerfile` is claimed by the default member, so it would exercise the owned
# branch instead. public/ is NOT allowlisted, and its row is what keeps it that
# way: the tree carries executed JavaScript under it, so the subtree stays in
# scope. The workflow row's template on the base and the installed workflow
# carry identical bytes, which is exactly what the removed self-modification
# bypass cleared on; the workflow is in scope, so with no marker it denies.
@test "golden table: each path set routes the merge to its stated decision" {
  local row expected first_path first_content second_path second_content
  local rows=(
    'allow|wiki/x.md|doc||'
    'deny|app/x.ts|export const x = 1;||'
    'deny|app/x.ts|export const x = 1;|wiki/x.md|doc'
    'deny|.gaia/scripts/probe.sh|#!/bin/bash||'
    'deny|Makefile|all:||'
    'deny|public/logo.svg|<svg></svg>||'
    'deny|.github/workflows/fixture-audit.yml|name: Code Review Audit||'
  )
  golden_setup
  for row in "${rows[@]}"; do
    IFS='|' read -r expected first_path first_content second_path second_content <<<"$row"
    echo "case: $expected $first_path ${second_path}"
    git -C "$GREPO" checkout --quiet -B feature main
    rm -rf "$GREPO/.gaia/local"
    if [ -n "$second_path" ]; then
      golden_commit "$first_path" "$first_content" "$second_path" "$second_content"
    else
      golden_commit "$first_path" "$first_content"
    fi
    golden_run_hook
    [ "$status" -eq 0 ]
    if [ "$expected" = allow ]; then
      grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
    else
      grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
    fi
  done
  golden_teardown
}

# ---------------------------------------------------------------------------
# Part 5: absent module -> DENY. A COPY of the hook in a sandbox
# `.claude/hooks/` with no `lib/` at all must deny, never allow. Never `mv`
# the real module aside: a bats run must not mutate the working tree, and a
# copied hook exercises the same BASH_SOURCE-relative miss.
# ---------------------------------------------------------------------------

@test "absent classifier module: a copied hook with no lib/ directory denies, never allows" {
  SANDBOX=$(mktemp -d -t audit-scope-absent-XXXXXX)
  mkdir -p "$SANDBOX/.claude/hooks"
  cp "$HOOK" "${HOOK%.sh}"-*.sh "$SANDBOX/.claude/hooks/"
  chmod +x "$SANDBOX/.claude/hooks/pr-merge-audit-check.sh"

  # Seed the libraries the gate reaches BEFORE its classifier load, and no
  # others, so it arms normally and reaches ITS OWN classifier-absent deny
  # below rather than an earlier one. Only jq-availability.sh, hook-payload.sh
  # and verb-arming.sh can send it to a different arm: the first refuses
  # fail-loud with its own text, ahead of even the arming library, the second
  # (the payload reader, loaded right after the first) refuses the same way
  # naming itself, and the third denies every Bash tool call with its own. The rest keep the gate on
  # its ordinary path rather than change which arm it lands on, so a miss
  # there is invisible to the assertions below: repo-scope.sh is one of the
  # libraries the classifier deny itself names, so its own miss reads verbatim
  # as the text grepped for, and an absent verb-arming-walk.sh only degrades
  # the arming decision to its raw match.
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$REPO_ROOT/.claude/hooks/lib/jq-availability.sh" "$SANDBOX/.claude/hooks/lib/jq-availability.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/hook-payload.sh" "$SANDBOX/.claude/hooks/lib/hook-payload.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming.sh" "$SANDBOX/.claude/hooks/lib/verb-arming.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming-walk.sh" "$SANDBOX/.claude/hooks/lib/verb-arming-walk.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming-view.sh" "$SANDBOX/.claude/hooks/lib/verb-arming-view.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming-live-helpers.sh" "$SANDBOX/.claude/hooks/lib/verb-arming-live-helpers.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming-live-view.sh" "$SANDBOX/.claude/hooks/lib/verb-arming-live-view.sh"
  cp "$REPO_ROOT"/.claude/hooks/lib/repo-scope*.sh "$SANDBOX/.claude/hooks/lib/"
  # The unattended-merge sibling denies without the autonomy library, ahead of
  # the classifier, so the sandbox carries it.
  mkdir -p "$SANDBOX/.gaia/scripts"
  cp "$REPO_ROOT/.gaia/scripts/autonomy-lib.sh" "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$SANDBOX/.gaia/scripts/"

  json=$(jq -n '{tool_name: "Bash", tool_input: {command: "gh pr merge 1 --squash"}}')
  invoke_hook_in "$SANDBOX" "$json" "$SANDBOX/.claude/hooks/pr-merge-audit-check.sh"
  rm -rf "$SANDBOX"

  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  # The classifier-specific deny text, not the arming library's: proves the
  # gate reached the classifier check rather than denying earlier for an
  # unrelated reason (audit finding DP-008).
  grep -qF -- 'cannot load the ownership classifier' <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# SEC-007: every machinery path is claimed by the committed .gaia/audit-ci.yml
# roster, the only roster the module loads. Bats suites are release-excluded,
# so this only ever runs where the maintainer members exist.
# ---------------------------------------------------------------------------

# Assert audit_owner_for_path returns a non-empty owner for every machinery
# path in $AUDIT_MACHINERY_PATHS, against the roster the caller already
# init'd. Real files
# under a `/**` prefix are enumerated from $REPO_ROOT. Ends in the pass/fail
# check, so it is safe as a @test's final command.
assert_every_machinery_path_owned() {
  local entry prefix rep owner tracked fail=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      "#"*) continue ;;
      *"/**")
        prefix="${entry%\*\*}"
        rep="${prefix}__representative__.sh"
        owner="$(audit_owner_for_path "$rep")"
        if [ -z "$owner" ]; then
          echo "representative path unowned: $rep" >&2
          fail=1
        fi
        while IFS= read -r -d '' tracked; do
          [ -n "$tracked" ] || continue
          owner="$(audit_owner_for_path "$tracked")"
          if [ -z "$owner" ]; then
            echo "tracked file unowned: $tracked (entry $entry)" >&2
            fail=1
          fi
        # gaia-lint-ignore whole-tree-mark-guard: the only test that reaches this walk carries the per-test mark
        done < <(git -C "$REPO_ROOT" ls-files -z "$prefix")
        ;;
      *)
        owner="$(audit_owner_for_path "$entry")"
        if [ -z "$owner" ]; then
          echo "machinery path unowned: $entry" >&2
          fail=1
        fi
        ;;
    esac
  done <<EOF
$AUDIT_MACHINERY_PATHS
EOF
  [ "$fail" -eq 0 ]
}

# bats test_tags=whole-tree
@test "SEC-007: audit_owner_for_path returns a non-empty member for every machinery path" {
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  # shellcheck source=/dev/null
  . "$MACHINERY_LIBRARY"
  audit_scope_init "$REPO_ROOT"

  assert_every_machinery_path_owned
}

@test "audit_scope_init fails closed with a named reason on a roster-less root" {
  # There is no fallback roster: a root whose .gaia/audit-ci.yml is absent or
  # carries no auditors: block must return non-zero and name the file, never
  # leave a populated roster behind from an earlier call.
  EMPTY_ROOT=$(mktemp -d -t audit-scope-noroster-XXXXXX)
  mkdir -p "$EMPTY_ROOT/.gaia"
  printf 'audit_authors: []\n' > "$EMPTY_ROOT/.gaia/audit-ci.yml"
  run bash -c '
    . "$1"
    audit_scope_init "$2" || { echo "rc=$?"; audit_owner_for_path "app/x.ts"; exit 0; }
    echo "rc=0"
  ' _ "$SCOPE_LIBRARY" "$EMPTY_ROOT"
  rm -rf "$EMPTY_ROOT"

  [ "$status" -eq 0 ]
  grep -qF 'rc=1' <<<"$output" || return 1
  grep -qF 'no auditors: roster in' <<<"$output" || return 1
  grep -qF '/.gaia/audit-ci.yml' <<<"$output" || return 1
  # Nothing owns a path once init has failed.
  [ "$(grep -c 'code-audit' <<<"$output")" -eq 0 ]
}

# Each row names a path no other invariant reaches, so this table is its pin.
# - .githooks/pre-commit is the Quality Gate floor for every commit and is
#   POSIX shell, so the shell member (which holds the shellcheck oracle) owns
#   it. Without a glob claiming it, a PR changing the hook alongside other owned
#   surfaces merges the hook with no member responsible. It is deliberately NOT
#   in AUDIT_MACHINERY_PATHS (that list holds bytes that change what a member
#   reviews, who reviews it, where a clearance lands, or whether a clearance is
#   believed; this hook gates commits, not audits), so SEC-007 does not reach it.
# - The default member's own `pnpm-workspace.yaml` glob never crosses a `/`, so
#   it claims the repository-root file, which carries the supply-chain policy
#   for every workspace member, the CLI included.
# - `.gaia/cli/` carries its own vitest, eslint and prettier configs beside src/. The default member's
#   bare `*.config.ts` / `*.config.mjs` globs never cross a `/`, so they claim
#   only the repository-root files; without the node member's glob a PR whose
#   only change is one of them dispatches no member. vitest.config.ts is
#   the sharpest, since its `setupFiles` executes arbitrary code in every CLI
#   test run. The root files stay with the default member, so the two do not
#   collide.
# - UAT-002: no member owns `.claude/skills/**`, so a skills .md file and a
#   non-.md helper are ownerless.
# Rows are path | owner (empty: ownerless).
# bats test_tags=whole-tree
@test "ownership of named paths: each resolves to its stated owner" {
  local row path expected
  local rows=(
    '.githooks/pre-commit|code-audit-maintainer-shell'
    'pnpm-workspace.yaml|code-audit-frontend'
    '.gaia/cli/vitest.config.ts|code-audit-maintainer-node'
    '.gaia/cli/eslint.config.mjs|code-audit-maintainer-node'
    '.gaia/cli/prettier.config.mjs|code-audit-maintainer-node'
    'vitest.config.ts|code-audit-frontend'
    'eslint.config.mjs|code-audit-frontend'
    '.claude/skills/gaia/references/debt.md|'
    '.claude/skills/gaia/helper.py|'
  )
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  audit_scope_init "$REPO_ROOT"
  for row in "${rows[@]}"; do
    IFS='|' read -r path expected <<<"$row"
    echo "case: $path"
    [ "$(audit_owner_for_path "$path")" = "$expected" ]
  done
}

@test "the shared awk source carries exactly one copy of each transformation" {
  # The module concatenates $_AUDIT_SCOPE_GLOB_AWK into both of its awk
  # programs precisely so the glob compiler and the YAML unquoter exist once.
  # That is a claim in the file's own prose, and a second copy would reintroduce
  # the silent-drift failure the sharing exists to prevent while every test here
  # still passed, so it is asserted rather than trusted.
  local scope_library_path="$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
  [ "$(grep -c '^ *function glob_to_regex(' "$scope_library_path")" -eq 1 ]
  [ "$(grep -c '^ *function unq(' "$scope_library_path")" -eq 1 ]
}

@test "the unowned: reader compiles a glob to the same regex the roster reader does" {
  # The sharing above is only worth asserting if the two readers actually agree,
  # so this pins the outcome rather than the arrangement: one glob spelling, fed
  # through each parser, must compile identically.
  local yaml_roster yaml_unowned from_roster from_unowned
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  yaml_roster="$(printf 'auditors:\n  - name: code-audit-x\n    globs:\n      - ".gaia/**/*.sh"\n')"
  yaml_unowned="$(printf 'unowned:\n  - ".gaia/**/*.sh"\n')"
  from_roster="$(printf '%s\n' "$yaml_roster" | _audit_scope_parse_auditors | awk '$1 == "GLOB" { print $3 }')"
  from_unowned="$(printf '%s\n' "$yaml_unowned" | _audit_scope_parse_unowned | cut -f3)"
  [ -n "$from_roster" ]
  [ "$from_roster" = "$from_unowned" ]
}

# SPEC-092 C5 exempt row: audit-scope.sh reads no package descriptor, because the
# `*/*` arm already puts every nested path in scope. A apps/web/ path therefore
# classifies exactly as its retired root form does, and no registry state can
# move it (the second test pins that nothing here reads one). apps/web/.claude/**
# and apps/web/CLAUDE.md stay in scope on purpose (C14: code-audit-frontend
# claims them), so a package harness diff is never allowlisted past review.
@test "package paths: apps/web/ classifies in scope like the root form" {
  run bash -c '. "$1"; for p in apps/web/app/routes/x.tsx app/routes/x.tsx apps/web/.claude/rules/x.md apps/web/CLAUDE.md apps/web/public/logo.svg; do audit_out_of_scope_allowlisted "$p" && echo "allowlisted:$p" || echo "in-scope:$p"; done' _ "$SCOPE_LIBRARY"
  [ "$status" -eq 0 ]
  local path
  for path in apps/web/app/routes/x.tsx app/routes/x.tsx apps/web/.claude/rules/x.md apps/web/CLAUDE.md apps/web/public/logo.svg; do
    grep -qxF "in-scope:$path" <<<"$output" || { echo "$path not in scope"; return 1; }
  done
}

@test "package paths: the classifier names no package registry or descriptor (structural, no descriptor read)" {
  run grep -n "gaia-packages\|packages\.json\|gaia\.package" "$SCOPE_LIBRARY"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Light-review roster keys and the public glob matcher.
# ---------------------------------------------------------------------------

# Writes a one-member roster fixture to <directory>/.gaia/audit-ci.yml; the
# member body (everything after `globs:`' list) comes from the second argument.
write_light_roster() {
  local directory="$1" body="$2"
  mkdir -p "$directory/.gaia"
  printf '%s\n' "$body" > "$directory/.gaia/audit-ci.yml"
}

LIGHT_ROSTER_WITH_KEYS='auditors:
  - name: code-audit-light
    globs:
      - "owned/**"
    light_review: true
    light_line_cap: 50   # inline comment is stripped
    light_hard_full:
      - "owned/tests/**"
      # a comment between items never ends the list
      - "*.config.ts"
    audience: adopter
    default: true
  - name: code-audit-plain
    globs:
      - "plain/**"
    audience: adopter'

# Rows are roster | member | light_review value | status | output (with \t and
# \n escapes). The `keys` roster is LIGHT_ROSTER_WITH_KEYS; the `value` roster
# is one member whose light_review takes the row's value and whose cap is the
# non-numeric `abc`, which comes back raw; `absent` is a root with no roster.
@test "audit_roster_light_config: each roster and member answers its opt-in, cap and hard-Full items" {
  local row roster member value expected_status expected_output fixture
  local rows=(
    'keys|code-audit-light||0|true\t50\nHARDFULL\towned/tests/**\nHARDFULL\t*.config.ts'
    'keys|code-audit-plain||0|false\t-'
    'keys|code-audit-no-such-member||0|false\t-'
    'value|code-audit-light|yes|0|false\tabc'
    'value|code-audit-light|"true"|0|false\tabc'
    'value|code-audit-light|True|0|false\tabc'
    'value|code-audit-light|1|0|false\tabc'
    'value|code-audit-light||0|false\tabc'
    'absent|code-audit-light||1|'
  )
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  fixture="$BATS_TEST_TMPDIR/light-roster"
  for row in "${rows[@]}"; do
    IFS='|' read -r roster member value expected_status expected_output <<<"$row"
    echo "case: $roster $member light_review='$value'"
    rm -rf "$fixture"
    case "$roster" in
      keys) write_light_roster "$fixture" "$LIGHT_ROSTER_WITH_KEYS" ;;
      value)
        write_light_roster "$fixture" "auditors:
  - name: code-audit-light
    globs:
      - \"owned/**\"
    light_review: $value
    light_line_cap: abc
    audience: adopter"
        ;;
    esac
    run audit_roster_light_config "$fixture" "$member"
    [ "$status" -eq "$expected_status" ]
    [ "$output" = "$(printf '%b' "$expected_output")" ]
  done
}

@test "light_hard_full items never reach ownership, and the ownership parser's output is unchanged by the keys" {
  local fixture bare
  fixture="$(mktemp -d -t audit-light-roster-XXXXXX)"
  write_light_roster "$fixture" "$LIGHT_ROSTER_WITH_KEYS"
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  audit_scope_init "$fixture"
  # `*.config.ts` is a hard-Full item only; no member owns a root config file.
  run audit_owners_for_paths <<<"vite.config.ts"
  [ "$output" = "$(printf 'vite.config.ts\t-')" ]
  # `owned/tests/x.ts` is owned through `owned/**` and by nothing the list adds.
  run audit_owners_for_paths <<<"owned/tests/x.ts"
  [ "$output" = "$(printf 'owned/tests/x.ts\tcode-audit-light')" ]
  # The ownership records are byte-identical with the three keys stripped.
  bare="$(printf '%s\n' "$LIGHT_ROSTER_WITH_KEYS" | grep -v -e 'light_' -e 'owned/tests/\*\*' -e '\*\.config\.ts' -e 'a comment between items')"
  [ "$(_audit_scope_parse_auditors <<<"$LIGHT_ROSTER_WITH_KEYS")" = "$(_audit_scope_parse_auditors <<<"$bare")" ]
  rm -rf "$fixture"
}

@test "a hyphenated key is the leak the snake_case rule prevents: its items become owned globs" {
  local fixture
  fixture="$(mktemp -d -t audit-light-roster-XXXXXX)"
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"

  # Hyphenated spelling: the ownership parser's key pattern is [A-Za-z_]+, so
  # `light-hard-full:` does not end `globs:` and `leaked/**` is read as an
  # owned glob. The light reader sees no list at all.
  write_light_roster "$fixture" 'auditors:
  - name: code-audit-light
    globs:
      - "owned/**"
    light-hard-full:
      - "leaked/**"
    audience: adopter'
  audit_scope_init "$fixture"
  run audit_owners_for_paths <<<"leaked/x.ts"
  [ "$output" = "$(printf 'leaked/x.ts\tcode-audit-light')" ]
  run audit_roster_light_config "$fixture" code-audit-light
  [ "$output" = "$(printf 'false\t-')" ]

  # Snake_case spelling of the same roster: the item reaches no ownership.
  write_light_roster "$fixture" 'auditors:
  - name: code-audit-light
    globs:
      - "owned/**"
    light_hard_full:
      - "leaked/**"
    audience: adopter'
  audit_scope_init "$fixture"
  run audit_owners_for_paths <<<"leaked/x.ts"
  [ "$output" = "$(printf 'leaked/x.ts\t-')" ]
  run audit_roster_light_config "$fixture" code-audit-light
  rm -rf "$fixture"
  [ "${lines[1]}" = "$(printf 'HARDFULL\tleaked/**')" ]
}

# glob, path, expected. Tab-separated; every glob is also given to a roster so
# ownership has to agree with the matcher, pair by pair.
GLOB_MATCH_TABLE=$'**/x\tx\tmatch
**/x\ta/b/x\tmatch
**/x\ta/b/xy\tnomatch
*.config.ts\tvite.config.ts\tmatch
*.config.ts\tapps/web/vite.config.ts\tnomatch
*.config.ts\tviteXconfigXts\tnomatch
apps/web/*.config.ts\tapps/web/vite.config.ts\tmatch
apps/web/*.config.ts\tapps/web/sub/vite.config.ts\tnomatch
apps/web/app/**/tests/**\tapps/web/app/a/tests/b.ts\tmatch
apps/web/app/**/tests/**\tapps/web/app/a/b.ts\tnomatch
apps/web/.claude/**\tapps/web/.claude/rules/a.md\tmatch
apps/web/.claude/**\tapps/web/CLAUDE.md\tnomatch
.github/workflows/**\t.github/workflows/ci.yml\tmatch
tsconfig*.json\ttsconfig.app.json\tmatch
tsconfig*.json\tapps/web/tsconfig.json\tnomatch
package.json\tapps/web/package.json\tnomatch
.npmrc\tXnpmrc\tnomatch
apps/web/**\tapps/web/a/b/c.ts\tmatch'

# Prints one line per pair on which the matcher in <library> disagrees with the
# table or with the ownership classifier in the same library. Empty means they
# agree everywhere.
glob_matcher_disagreements() {
  local library="$1"
  GLOB_MATCH_TABLE="$GLOB_MATCH_TABLE" LIBRARY="$library" bash -c '
    . "$LIBRARY"
    fixture="$(mktemp -d)"
    mkdir -p "$fixture/.gaia"
    while IFS=$'"'"'\t'"'"' read -r glob path expected; do
      printf "auditors:\n  - name: code-audit-parity\n    globs:\n      - \"%s\"\n    audience: adopter\n" "$glob" > "$fixture/.gaia/audit-ci.yml"
      audit_scope_init "$fixture"
      owner="$(audit_owner_for_path "$path")"
      audit_glob_matches "$glob" "$path"
      matcher_status=$?
      if [ "$matcher_status" -eq 0 ]; then matcher_says=match; elif [ "$matcher_status" -eq 1 ]; then matcher_says=nomatch; else matcher_says=error; fi
      if [ -n "$owner" ]; then owner_says=match; else owner_says=nomatch; fi
      if [ "$matcher_says" != "$expected" ] || [ "$owner_says" != "$matcher_says" ]; then
        printf "%s | %s | table=%s matcher=%s ownership=%s\n" "$glob" "$path" "$expected" "$matcher_says" "$owner_says"
      fi
    done <<<"$GLOB_MATCH_TABLE"
    rm -rf "$fixture"
  '
}

@test "audit_glob_matches: every table pair matches as stated and agrees with ownership" {
  [ "$(printf '%s\n' "$GLOB_MATCH_TABLE" | grep -c .)" -ge 18 ]
  run glob_matcher_disagreements "$SCOPE_LIBRARY"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "audit_glob_matches: a missing or empty argument exits 2 and prints nothing" {
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  run audit_glob_matches
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run audit_glob_matches "**/x"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run audit_glob_matches "" "x"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run audit_glob_matches "**/x" ""
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "audit_glob_matches: regex metacharacters and backslashes in a path are literal data" {
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  run audit_glob_matches 'a.b' 'aXb'
  [ "$status" -eq 1 ]
  run audit_glob_matches 'a.b' 'a.b'
  [ "$status" -eq 0 ]
  # Passed through the environment, so a backslash stays a backslash.
  run audit_glob_matches 'dir/*' 'dir/a\nb'
  [ "$status" -eq 0 ]
  run audit_glob_matches 'dir/*' 'dir/a"; system("echo pwned"); "'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
