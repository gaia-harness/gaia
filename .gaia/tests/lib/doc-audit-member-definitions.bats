#!/usr/bin/env bats
#
# Doc-conformance suite for the Code Audit Team member definitions and the
# shared member protocol they point at.
#
# What it guards. A member reviews and reports and nothing else: it runs no
# `gh issue` command, carries no out-of-scope disposition pipeline, and keeps
# its handshake, sidecar, ledger accounting and holistic class list in one
# shipped protocol file rather than in a copy of its own (UAT-001, UAT-009).
# The frontend definition stays inside a byte budget so the text is removed,
# not merely moved (UAT-041). Every definition, the protocol, and the audit
# round procedure's dispatch template make the definition re-read conditional on the
# scope resolver's `DEFINITION=reread` line (UAT-011). The protocol carries no
# CI arm and no trailer stamping, and ships without leaking a maintainer-only
# name outside its marker blocks.
#
# The member set is derived from the `code-audit-*.md` glob, so a new member
# joins every check by existing; the roster test pins the known members as a
# floor so an empty or short glob fails rather than greening every loop.
#
# Each target reads through an env override that defaults to the real file,
# so a mutant copy proves a case can fail without touching the tree.
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  AGENTS_DIRECTORY="${DOC_MEMBER_DEFINITIONS_AGENTS:-$REPO_ROOT/.claude/agents}"
  PROTOCOL="${DOC_MEMBER_DEFINITIONS_PROTOCOL:-$REPO_ROOT/.claude/hooks/lib/audit-member-protocol.md}"
  DISPATCH_TEMPLATE_PAGE="${DOC_MEMBER_DEFINITIONS_DISPATCH_PAGE:-$REPO_ROOT/wiki/concepts/Audit Round Procedure.md}"
  RELEASE_EXCLUDE="${DOC_MEMBER_DEFINITIONS_RELEASE_EXCLUDE:-$REPO_ROOT/.gaia/release-exclude}"
  FRONTEND="$AGENTS_DIRECTORY/code-audit-frontend.md"
  PROTOCOL_PATH='.claude/hooks/lib/audit-member-protocol.md'

  MEMBERS=()
  local member_file
  # gaia-lint-ignore whole-tree-mark-guard: every test that uses the member roster this collects carries the
  # per-test mark
  for member_file in "$AGENTS_DIRECTORY"/code-audit-*.md; do
    [ -f "$member_file" ] && MEMBERS+=("$member_file")
  done
}

# strip_maintainer_blocks <file>: prints the file without its maintainer-only
# marker blocks, the text an adopter's scrubbed copy carries.
strip_maintainer_blocks() {
  awk '
    index($0, "<!-- gaia:maintainer-only:start -->") { inside = 1; next }
    index($0, "<!-- gaia:maintainer-only:end -->") { inside = 0; next }
    !inside { print }
  ' "$1"
}

# section_text <file> <exact heading line>: prints the section body up to the
# next heading of the same or a higher level.
section_text() {
  awk -v want="$2" '
    $0 == want { inside = 1; level = index($0, " "); next }
    inside && /^#+ / && index($0, " ") <= level { exit }
    inside { print }
  ' "$1"
}

# --- the roster every per-member loop walks ---------------------------------

# bats test_tags=whole-tree
@test "the member glob resolves to at least the four known members, none empty" {
  [ "${#MEMBERS[@]}" -ge 4 ] || { echo "only ${#MEMBERS[@]} member definitions found" >&2; return 1; }
  local member
  for member in code-audit-frontend code-audit-github-workflows code-audit-maintainer-node code-audit-maintainer-shell; do
    [ -s "$AGENTS_DIRECTORY/${member}.md" ] || { echo "${member}.md is missing or empty" >&2; return 1; }
  done
}

# --- UAT-001: members run no gh issue command and carry no disposition pipeline

# bats test_tags=whole-tree
@test "UAT-001: no member definition names a gh issue command or the file-tech-debt procedure" {
  local member_file hits
  for member_file in "${MEMBERS[@]}"; do
    hits="$(grep -nE -- 'gh issue|file-tech-debt' "$member_file" || true)"
    [ -z "$hits" ] || { echo "$member_file: $hits" >&2; return 1; }
  done
}

# --- UAT-007: the frontend definition carries no self-heal machinery ---------

# --- UAT-009: one shared protocol, pointed at by every member -----------------

# bats test_tags=whole-tree
@test "UAT-009: no member definition carries a handshake, marker, sidecar or holistic class heading, and each names the protocol" {
  local member_file hits
  for member_file in "${MEMBERS[@]}"; do
    hits="$(grep -niE -- '^#{2,3} .*(gate handshake|audit marker|findings sidecar|holistic class assignment)' "$member_file" || true)"
    [ -z "$hits" ] || { echo "$member_file: $hits" >&2; return 1; }
    grep -qF -- "$PROTOCOL_PATH" "$member_file" || { echo "$member_file does not name $PROTOCOL_PATH" >&2; return 1; }
  done
}

@test "UAT-009: the protocol ships: it is absent from the release-exclude list" {
  [ -s "$RELEASE_EXCLUDE" ] || return 1
  grep -qxF -- "$PROTOCOL_PATH" "$RELEASE_EXCLUDE" && { echo "$PROTOCOL_PATH is still release-excluded" >&2; return 1; }
  true
}

@test "the protocol's maintainer-only markers are balanced and alternate" {
  local unbalanced
  unbalanced="$(awk '
    index($0, "<!-- gaia:maintainer-only:start -->") { if (inside) { print NR; exit } inside = 1; next }
    index($0, "<!-- gaia:maintainer-only:end -->") { if (!inside) { print NR; exit } inside = 0; next }
    END { if (inside) print "EOF" }
  ' "$PROTOCOL")"
  [ -z "$unbalanced" ] || { echo "marker imbalance at $unbalanced" >&2; return 1; }
}

@test "the protocol and the frontend definition name no maintainer-only member or excluded path outside marker blocks" {
  local shipped_file hits
  for shipped_file in "$PROTOCOL" "$FRONTEND"; do
    hits="$(strip_maintainer_blocks "$shipped_file" | grep -nE -- 'code-audit-maintainer-(shell|node)|\.gaia/tests/|\.gaia/cli/src' || true)"
    [ -z "$hits" ] || { echo "$shipped_file: $hits" >&2; return 1; }
  done
}

# --- UAT-041: the byte budget -------------------------------------------------

@test "UAT-041: the frontend definition is at most 70,000 bytes and with the protocol at most 100,000" {
  local frontend_bytes protocol_bytes
  frontend_bytes="$(wc -c <"$FRONTEND" | tr -d ' ')"
  protocol_bytes="$(wc -c <"$PROTOCOL" | tr -d ' ')"
  [ "$frontend_bytes" -gt 0 ] && [ "$protocol_bytes" -gt 0 ] || return 1
  [ "$frontend_bytes" -le 70000 ] || { echo "frontend definition is $frontend_bytes bytes" >&2; return 1; }
  [ $((frontend_bytes + protocol_bytes)) -le 100000 ] || { echo "frontend plus protocol is $((frontend_bytes + protocol_bytes)) bytes" >&2; return 1; }
}

# --- UAT-011: the definition re-read is conditional everywhere ------------------

# conditional_reread_line <file>: prints the lines that make the re-read
# conditional, naming both resolver outcomes and the word "only".
conditional_reread_line() {
  grep -F -- 'DEFINITION=reread' "$1" | grep -F -- 'DEFINITION=unchanged' | grep -wF -- 'only' || true
}

# bats test_tags=whole-tree
@test "UAT-011: every member definition and the protocol make the re-read conditional on DEFINITION=reread" {
  local audited_file
  for audited_file in "${MEMBERS[@]}" "$PROTOCOL"; do
    [ -n "$(conditional_reread_line "$audited_file")" ] || { echo "$audited_file states no conditional re-read" >&2; return 1; }
  done
}

@test "UAT-011: the audit round procedure dispatch template makes the re-read conditional, with no unconditional line" {
  [ -n "$(conditional_reread_line "$DISPATCH_TEMPLATE_PAGE")" ] || { echo "the template states no conditional re-read" >&2; return 1; }
  local unconditional
  unconditional="$(grep -F -- 'read your own agent definition' "$DISPATCH_TEMPLATE_PAGE" | grep -vF -- 'DEFINITION=reread' || true)"
  [ -z "$unconditional" ] || { echo "unconditional re-read line: $unconditional" >&2; return 1; }
  grep -qF -- 'MANDATORY SECOND ACTION, still before any review: read your own agent definition' "$DISPATCH_TEMPLATE_PAGE" && return 1
  true
}

# --- UAT-017 and UAT-033: no CI arm and no trailer stamping -------------------

# --- UAT-028: the advisory step uses the deterministic advisory command -------

@test "UAT-028: the frontend's advisory step runs gaia update-deps advisories, with no pnpm audit recipe" {
  local advisory
  advisory="$(section_text "$FRONTEND" '### Dependency-CVE advisory')"
  [ -n "$advisory" ] || { echo "no Dependency-CVE advisory section" >&2; return 1; }
  grep -qF -- 'gaia update-deps advisories' <<<"$advisory" || return 1
  grep -qF -- 'pnpm audit' "$FRONTEND" && { echo "the frontend definition still names pnpm audit" >&2; return 1; }
  grep -qE -- 'jq .*dep-audit-baseline|dep-audit-baseline.*jq' "$FRONTEND" && { echo "a baseline jq recipe survives" >&2; return 1; }
  true
}

# --- the frontend member's tool allowlist and specialist wiring ---------------
#
# Each check below is a function over a definition file, so a green test runs it
# on the real definition and its red twin runs it on a scratch copy altered in
# the one place the check reads, which it must reject.

# insert_after <file> <awk regex> <text>: prints the file with <text> on a new
# line after every line matching the regex.
insert_after() {
  awk -v pattern="$2" -v text="$3" '{ print } $0 ~ pattern { print text }' "$1"
}

# frontmatter_tools_line <file>: prints the `tools:` line of the frontmatter.
frontmatter_tools_line() {
  awk '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { exit }
    inside && /^tools:/ { print }
  ' "$1"
}

check_tools_allowlist() {
  [ "$(frontmatter_tools_line "$1")" = 'tools: Agent, Bash, Read, Write' ]
}

check_specialist_dispatch_site() {
  local how_to_run
  how_to_run="$(section_text "$1" '### How to run')"
  grep -qF -- 'subagent_type: "audit-rule-specialist"' <<<"$how_to_run" || return 1
  grep -qE -- '(^|[^a-z])(model|effort):' <<<"$how_to_run" && return 1
  grep -qF -- 'general-purpose' <<<"$how_to_run" && return 1
  return 0
}

check_specialists_flag_and_gate() {
  local how_to_run resolver_line
  resolver_line="$(grep -E -- '^<root>/\.gaia/scripts/audit-resolve-scope\.sh --member ' "$1")"
  [ -n "$resolver_line" ] || return 1
  case "$resolver_line" in *' --specialists') ;; *) return 1 ;; esac
  how_to_run="$(section_text "$1" '### How to run')"
  grep -qF -- 'on the `SPECIALIST=` lines' <<<"$how_to_run" || return 1
  grep -qF -- '`t(`' <<<"$how_to_run" && return 1
  return 0
}

check_oracle_script_call() {
  local how_to_run
  how_to_run="$(section_text "$1" '### How to run')"
  grep -qF -- "audit-frontend-oracles.sh' --root '<root>' --base '<BASE_SHA>'" <<<"$how_to_run" || return 1
  grep -qF -- '--base <BASE_SHA>' "$1" && return 1
  grep -qF -- 'npx -y react-doctor' "$1" && return 1
  grep -qF -- 'pnpm knip --reporter json' "$1" && return 1
  return 0
}

check_refuter_is_a_conditional_read() {
  local gate
  gate="$(section_text "$1" '## Finding Proof Gate (holistic reviewer)')"
  grep -qF -- '.claude/hooks/lib/audit-frontend-refuter.md' <<<"$gate" || return 1
  grep -qF -- 'when none survives, do not Read it' <<<"$gate" || return 1
  grep -qF -- '**Hardened retry prefix**' <<<"$gate" || return 1
  grep -qF -- 'You are an adversarial reviewer' "$1" && return 1
  return 0
}

check_moved_prose_is_gone() {
  local deleted extension_loading
  for deleted in '## Durable knowledge' 'Candidate wiki updates' 'Durable knowledge' '### Subagent instructions template' '### Subagent 2: TypeScript' 'wrong, or will produce broken work'; do
    grep -qF -- "$deleted" "$1" && return 1
  done
  extension_loading="$(section_text "$1" '## Extension Loading')"
  grep -qw -- 'Glob' <<<"$extension_loading" && return 1
  return 0
}

check_unknown_agent_type_fallback() {
  local how_to_run
  how_to_run="$(section_text "$1" '### How to run')"
  grep -qF -- 'Unknown agent type' <<<"$how_to_run" || return 1
  grep -qF -- 'relaunch Claude Code to load the new agent types' <<<"$how_to_run"
}

check_flow_list_is_required() {
  local extension_loading
  extension_loading="$(section_text "$1" '## Extension Loading')"
  grep -qF -- 'carries no inline list' <<<"$extension_loading" || return 1
  grep -qF -- 'error finding' <<<"$extension_loading"
}

# check_prose_cut <file> <line prefix>: the line starting with <prefix> is a
# fence-free rule of at most 300 characters naming no test path, and the next
# non-blank lines are a maintainer-only block naming one bats path and a test
# name substring in double quotes.
check_prose_cut() {
  local rule_line_number rule_line following
  rule_line_number="$(grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1)"
  [ -n "$rule_line_number" ] || return 1
  rule_line="$(sed -n "${rule_line_number}p" "$1")"
  [ "${#rule_line}" -le 300 ] || return 1
  case "$rule_line" in *.bats*) return 1 ;; esac
  following="$(sed -n "$((rule_line_number + 1)),$((rule_line_number + 5))p" "$1" | grep -v '^$')"
  [ "$(sed -n 1p <<<"$following")" = '<!-- gaia:maintainer-only:start -->' ] || return 1
  grep -qE -- '`[^`]+\.bats`.*"[^"]+"' <<<"$(sed -n 2p <<<"$following")" || return 1
  [ "$(sed -n 3p <<<"$following")" = '<!-- gaia:maintainer-only:end -->' ]
}

INCREMENTAL_SCOPE_PREFIX='**Incremental scope.**'
OWN_PATCH_PREFIX="**The branch's own patch, at HEAD, is the whole point.**"

# bats test_tags=whole-tree
@test "the frontend definition's tool allowlist is exactly Agent, Bash, Read and Write" {
  check_tools_allowlist "$FRONTEND"
}

@test "red twin: a widened tool allowlist is rejected" {
  sed 's/^tools: Agent, Bash, Read, Write$/tools: Agent, Bash, Read, Write, Edit/' "$FRONTEND" >"$BATS_TEST_TMPDIR/frontend.md"
  run check_tools_allowlist "$BATS_TEST_TMPDIR/frontend.md"
  [ "$status" -ne 0 ]
}

# bats test_tags=whole-tree
@test "the specialist dispatch names the audit-rule-specialist type and passes no model, no effort and no general-purpose type" {
  check_specialist_dispatch_site "$FRONTEND"
}

@test "red twin: a dispatch that passes an effort parameter is rejected" {
  insert_after "$FRONTEND" '^   - 1 × `Agent` call per `SPECIALIST=` line' '     effort: low' >"$BATS_TEST_TMPDIR/frontend.md"
  run check_specialist_dispatch_site "$BATS_TEST_TMPDIR/frontend.md"
  [ "$status" -ne 0 ]
}

# bats test_tags=whole-tree
@test "the resolver command carries --specialists and the dispatch gate reads the SPECIALIST lines" {
  check_specialists_flag_and_gate "$FRONTEND"
}

@test "red twin: the hand gate on t( references is rejected" {
  insert_after "$FRONTEND" '^2[.] [*][*]Gate each dispatch' '   - No files with `useTranslation` or `t(` references: skip the translation specialist' >"$BATS_TEST_TMPDIR/frontend.md"
  run check_specialists_flag_and_gate "$BATS_TEST_TMPDIR/frontend.md"
  [ "$status" -ne 0 ]
}

# bats test_tags=whole-tree
@test "the three oracles run as one quoted script call and no oracle command line survives in the definition" {
  check_oracle_script_call "$FRONTEND"
}

@test "red twin: an unquoted base in the oracle call is rejected" {
  sed "s/--base '<BASE_SHA>'/--base <BASE_SHA>/" "$FRONTEND" >"$BATS_TEST_TMPDIR/frontend.md"
  run check_oracle_script_call "$BATS_TEST_TMPDIR/frontend.md"
  [ "$status" -ne 0 ]
}

# bats test_tags=whole-tree
@test "the proof gate reads the refuter reference conditionally and carries no refuter prompt" {
  check_refuter_is_a_conditional_read "$FRONTEND"
}

@test "red twin: a refuter prompt left in the definition is rejected" {
  insert_after "$FRONTEND" '^[*][*]Adversarially verify every Critical and Major survivor' 'You are an adversarial reviewer. Your job is to REFUTE the finding below.' >"$BATS_TEST_TMPDIR/frontend.md"
  run check_refuter_is_a_conditional_read "$BATS_TEST_TMPDIR/frontend.md"
  [ "$status" -ne 0 ]
}

# bats test_tags=whole-tree
@test "moved and deleted prose is absent from the frontend definition" {
  check_moved_prose_is_gone "$FRONTEND"
}

@test "red twin: a restored durable knowledge section is rejected" {
  { cat "$FRONTEND"; printf '\n## Durable knowledge\n'; } >"$BATS_TEST_TMPDIR/frontend.md"
  run check_moved_prose_is_gone "$BATS_TEST_TMPDIR/frontend.md"
  [ "$status" -ne 0 ]
}

# bats test_tags=whole-tree
@test "the specialist dispatch step carries the unknown agent type fallback" {
  check_unknown_agent_type_fallback "$FRONTEND"
}

@test "red twin: a dispatch step without the relaunch note is rejected" {
  sed 's/relaunch Claude Code to load the new agent types/relaunch/' "$FRONTEND" >"$BATS_TEST_TMPDIR/frontend.md"
  run check_unknown_agent_type_fallback "$BATS_TEST_TMPDIR/frontend.md"
  [ "$status" -ne 0 ]
}

# bats test_tags=whole-tree
@test "Extension Loading makes a subagents line without an inline list an error finding" {
  check_flow_list_is_required "$FRONTEND"
}

@test "red twin: Extension Loading without the inline list sentence is rejected" {
  sed 's/carries no inline list/carries a list/' "$FRONTEND" >"$BATS_TEST_TMPDIR/frontend.md"
  run check_flow_list_is_required "$BATS_TEST_TMPDIR/frontend.md"
  [ "$status" -ne 0 ]
}

# bats test_tags=whole-tree
@test "each frontend prose cut is a short fence-free rule followed by a maintainer-only enforcer pointer" {
  check_prose_cut "$FRONTEND" "$INCREMENTAL_SCOPE_PREFIX"
  check_prose_cut "$FRONTEND" "$OWN_PATCH_PREFIX"
}

# bats test_tags=whole-tree
@test "each frontend enforcer pointer names a bats file in which exactly one test name carries the quoted substring" {
  local rule_prefix pointer enforcer_path substring matches
  for rule_prefix in "$INCREMENTAL_SCOPE_PREFIX" "$OWN_PATCH_PREFIX"; do
    pointer="$(grep -F -A 3 -- "$rule_prefix" "$FRONTEND" | grep -F -- 'Enforced by ')"
    enforcer_path="$(sed -E 's/^Enforced by `([^`]+)`.*/\1/' <<<"$pointer")"
    substring="$(sed -E 's/^[^"]*"([^"]+)".*/\1/' <<<"$pointer")"
    [ -f "$REPO_ROOT/$enforcer_path" ] || { echo "enforcer $enforcer_path does not exist" >&2; return 1; }
    matches="$(grep -E -- '^@test ' "$REPO_ROOT/$enforcer_path" | grep -cF -- "$substring" || true)"
    [ "$matches" -eq 1 ] || { echo "$enforcer_path: $matches @test lines carry: $substring" >&2; return 1; }
  done
}

@test "red twin: an enforcer path on the fence-free rule line is rejected, here and by the adopter-visible path guard" {
  sed 's#^\*\*Incremental scope\.\*\* #&See .gaia/tests/lib/enforcer.bats. #' "$FRONTEND" >"$BATS_TEST_TMPDIR/frontend.md"
  run check_prose_cut "$BATS_TEST_TMPDIR/frontend.md" "$INCREMENTAL_SCOPE_PREFIX"
  [ "$status" -ne 0 ]
  strip_maintainer_blocks "$BATS_TEST_TMPDIR/frontend.md" >"$BATS_TEST_TMPDIR/stripped.md"
  run grep -nE -- '\.gaia/tests/' "$BATS_TEST_TMPDIR/stripped.md"
  [ "$status" -eq 0 ]
}
