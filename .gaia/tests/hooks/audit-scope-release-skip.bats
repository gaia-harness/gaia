#!/usr/bin/env bats
# The ownership classifier's release-change skip: a member keyed
# `skip_gaia_release_changes: true` owns no manifest-`owned` file on a branch
# that changes .gaia/VERSION, and routes as before everywhere else.
#
# Fixtures come from .gaia/tests/helpers/release-skip-fixture.sh (its header
# names the roster and the branch kinds). Every case builds its repository in
# $BATS_TEST_TMPDIR; mutation cases copy the library under test there too.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   bash .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-scope-release-skip.bats
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIBRARY_DIRECTORY="$REPO_ROOT/.claude/hooks/lib"
  RESOLVER="$REPO_ROOT/.gaia/scripts/resolve-audit-members.sh"
  PRE_CHANGE_PARSER="$BATS_TEST_DIRNAME/fixtures/audit-scope-parser-pre-release-skip.awk"
  . "$REPO_ROOT/.gaia/tests/helpers/release-skip-fixture.sh"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  FIXTURE="$BATS_TEST_TMPDIR/fixture"
  release_skip_init "$FIXTURE"
  WITHOUT_KEYED="$BATS_TEST_TMPDIR/without-keyed.yml"
  release_skip_roster "$WITHOUT_KEYED" without-keyed
}

# owners_with <library-directory> <root> <config> <head> <merge-base-or-empty> <path>...:
# "<path>\t<owner>" lines with the context armed against main.
owners_with() {
  bash -c '
    library="$1" root="$2" config="$3" head="$4" merge_base="$5"; shift 5
    [ -z "${INNER_PATH:-}" ] || PATH="$INNER_PATH"
    . "$library/audit-scope.sh" || exit 9
    audit_scope_init "$root" "$config" || exit 9
    audit_scope_release_context "$root" main "$head" "$merge_base"
    printf "%s\n" "$@" | audit_owners_for_paths
  ' _ "$@"
}

# owner_of <path>: the owner with the real library, the fixture roster, HEAD.
owner_of() {
  owners_with "$LIBRARY_DIRECTORY" "$FIXTURE" "$FIXTURE/.gaia/audit-ci.yml" HEAD "" "$1" | cut -f2
}

# owner_without_keyed <path>: the owner with the keyed entry absent.
owner_without_keyed() {
  owners_with "$LIBRARY_DIRECTORY" "$FIXTURE" "$WITHOUT_KEYED" HEAD "" "$1" | cut -f2
}

# state_with <library-directory> <root> <config> [<head> [<merge-base>]]
state_with() {
  bash -c '
    [ -z "${INNER_PATH:-}" ] || PATH="$INNER_PATH"
    . "$1/audit-scope.sh" || exit 9
    audit_scope_init "$2" "$3" || exit 9
    audit_scope_release_context "$2" main "${4:-HEAD}" "${5:-}"
    audit_scope_release_context_state
  ' _ "$@"
}

resolve_members() {
  "$RESOLVER" --root "$FIXTURE" --base "$(git -C "$FIXTURE" merge-base main HEAD)"
}

# resolve_members_without_keyed: the resolver with the keyed entry removed
# from the working-tree roster it reads, restored afterwards.
resolve_members_without_keyed() {
  local saved="$BATS_TEST_TMPDIR/roster.saved" output status=0
  cp "$FIXTURE/.gaia/audit-ci.yml" "$saved"
  cp "$WITHOUT_KEYED" "$FIXTURE/.gaia/audit-ci.yml"
  output="$(resolve_members)" || status=$?
  cp "$saved" "$FIXTURE/.gaia/audit-ci.yml"
  printf '%s\n' "$output"
  return "$status"
}

lines_of() {
  printf '%s\n' "$@"
}

# ---------- roster key compatibility ---------------------------------------

# parser_globs_agree <audit-scope-library>: exit 0 when the pre-change parser
# fixture and the library's ownership parser give the keyed entry the same GLOB
# records, and that set is non-empty.
parser_globs_agree() {
  local old new
  old="$(awk -f "$PRE_CHANGE_PARSER" < "$FIXTURE/.gaia/audit-ci.yml" | awk '$1 == "GLOB" && $2 == "fixture-shell"')"
  new="$(bash -c '. "$1"; _audit_scope_parse_auditors < "$2"' _ "$1" "$FIXTURE/.gaia/audit-ci.yml" | awk '$1 == "GLOB" && $2 == "fixture-shell"')"
  [ "$(printf '%s\n' "$old" | grep -c '^GLOB ')" -eq 3 ] || return 1
  [ "$old" = "$new" ]
}

@test "a pre-change parser and the current one read the same globs for an entry carrying the skip key" {
  grep -q '^    skip_gaia_release_changes: true$' "$FIXTURE/.gaia/audit-ci.yml"
  parser_globs_agree "$LIBRARY_DIRECTORY/audit-scope.sh"
}

@test "the parser-compatibility check fails on a parser that reads the key line as a glob" {
  local scratch="$BATS_TEST_TMPDIR/mutated-parser"
  mkdir -p "$scratch"
  cp "$LIBRARY_DIRECTORY/audit-scope.sh" "$LIBRARY_DIRECTORY/audit-scope-release.sh" "$scratch/"
  awk '
    /Any other member-level scalar key/ && !done {
      print "      if (in_globs && raw ~ /skip_gaia_release_changes/) { nglobs++; globs[nglobs] = \"key\"; next }"
      done = 1
    }
    { print }
  ' "$LIBRARY_DIRECTORY/audit-scope.sh" > "$scratch/audit-scope.sh"
  grep -q 'globs\[nglobs\] = "key"' "$scratch/audit-scope.sh"
  run parser_globs_agree "$scratch/audit-scope.sh"
  [ "$status" -ne 0 ]
}

@test "skip members: only the literal true arms a member, in roster order; an absent roster exits 1" {
  local roster="$BATS_TEST_TMPDIR/keys.yml"
  printf '%s\n' 'auditors:' \
    '  - name: d' '    globs:' '      - "**"' '    default: true' \
    '  - name: quoted' '    globs:' '      - "a/**"' '    skip_gaia_release_changes: "true"' \
    '  - name: off' '    globs:' '      - "b/**"' '    skip_gaia_release_changes: false' \
    '  - name: on' '    globs:' '      - "c/**"' '    skip_gaia_release_changes: true # shipped shell' \
    '  - name: also' '    globs:' '      - "e/**"' '    skip_gaia_release_changes: true' > "$roster"
  run bash -c '. "$1"; audit_roster_release_skip_members "$2"' _ "$LIBRARY_DIRECTORY/audit-scope.sh" "$roster"
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines_of on also)" ]
  run bash -c '. "$1"; audit_roster_release_skip_members "$2"' _ "$LIBRARY_DIRECTORY/audit-scope.sh" "$BATS_TEST_TMPDIR/absent.yml"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  printf 'unowned:\n  - "x/**"\n' > "$BATS_TEST_TMPDIR/no-roster.yml"
  run bash -c '. "$1"; audit_roster_release_skip_members "$2"' _ "$LIBRARY_DIRECTORY/audit-scope.sh" "$BATS_TEST_TMPDIR/no-roster.yml"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ---------- release branch ---------------------------------------------------

@test "release branch: the keyed member is not dispatched, and the resolver agrees with the roster that lacks it" {
  release_skip_branch "$FIXTURE" release
  run resolve_members
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines_of fixture-default fixture-scripts)" ]
  local without
  without="$(resolve_members_without_keyed)"
  [ "$output" = "$without" ]
}

@test "release branch: each owned path resolves to exactly the owner it has with the keyed entry removed" {
  release_skip_branch "$FIXTURE" release
  [ "$(state_with "$LIBRARY_DIRECTORY" "$FIXTURE" "$FIXTURE/.gaia/audit-ci.yml")" = "armed 5" ]
  local path expected
  for path in .gaia/scripts/gaia-tool.sh .claude/hooks/gaia-guard.sh .gaia/scripts/gaia-new.sh .gaia/scripts/gaia-retired.sh .github/audit/gaia-audit.sh; do
    expected="$(owner_without_keyed "$path")"
    [ "$(owner_of "$path")" = "$expected" ] || { echo "$path: $(owner_of "$path") != $expected" >&2; return 1; }
  done
  [ "$(owner_of .gaia/scripts/gaia-tool.sh)" = fixture-scripts ]
  [ "$(owner_of .claude/hooks/gaia-guard.sh)" = fixture-default ]
  [ "$(owner_of .gaia/scripts/gaia-new.sh)" = fixture-scripts ]
  [ "$(owner_of .gaia/scripts/gaia-retired.sh)" = fixture-scripts ]
  [ "$(owner_of .github/audit/gaia-audit.sh)" = fixture-default ]
  # A path in no manifest keeps the keyed owner on the same armed branch.
  [ "$(owner_of scripts/unlisted.sh)" = fixture-shell ]
}

@test "release branch touching only an owned .github/audit script: the resolver output equals the keyed-entry-removed output" {
  git -C "$FIXTURE" checkout -q -b audit-only main
  printf '1.1.0\n' > "$FIXTURE/.gaia/VERSION"
  printf 'echo updated\n' > "$FIXTURE/.github/audit/gaia-audit.sh"
  git -C "$FIXTURE" commit -qam "update the shipped audit script"
  run resolve_members
  [ "$status" -eq 0 ]
  [ "$output" = fixture-default ]
  [ "$output" = "$(resolve_members_without_keyed)" ]
}

# ---------- ordinary branches --------------------------------------------------

@test "ordinary branch: adopter shell in no manifest belongs to the keyed member" {
  release_skip_branch "$FIXTURE" ordinary
  [ "$(state_with "$LIBRARY_DIRECTORY" "$FIXTURE" "$FIXTURE/.gaia/audit-ci.yml")" = "disarmed no-version-change" ]
  local path
  for path in .gaia/scripts/my-tool.sh scripts/deploy.sh tests/deploy.bats .claude/hooks/my-guard.sh; do
    [ "$(owner_of "$path")" = fixture-shell ] || { echo "$path: $(owner_of "$path")" >&2; return 1; }
  done
  run resolve_members
  [ "$output" = fixture-shell ]
}

@test "an adopter edit to an owned hook routes to the keyed member; the same edit with a VERSION bump does not" {
  release_skip_branch "$FIXTURE" hand-edit
  [ "$(owner_of .claude/hooks/gaia-guard.sh)" = fixture-shell ]
  run resolve_members
  [ "$output" = fixture-shell ]

  release_skip_branch "$FIXTURE" hand-edit-release
  run resolve_members
  [ "$status" -eq 0 ]
  [ "$output" = fixture-default ]
}

@test "mixed release branch: adopter shell keeps the keyed member dispatched" {
  release_skip_branch "$FIXTURE" mixed
  run resolve_members
  [ "$output" = "$(lines_of fixture-default fixture-scripts fixture-shell)" ]
  [ "$(owner_of scripts/deploy.sh)" = fixture-shell ]
  [ "$(owner_of .gaia/scripts/gaia-tool.sh)" = fixture-scripts ]
}

# ---------- every disarm reason fails toward over-review ----------------------

# disarmed_and_over_reviews <library-directory> <root> <config> <reason> [<head> [<merge-base>]]
disarmed_and_over_reviews() {
  local library="$1" root="$2" config="$3" reason="$4" head="${5:-HEAD}" merge_base="${6:-}" state owner
  state="$(state_with "$library" "$root" "$config" "$head" "$merge_base")"
  [ "$state" = "disarmed $reason" ] || { echo "state: $state" >&2; return 1; }
  owner="$(owners_with "$library" "$root" "$config" "$head" "$merge_base" .gaia/scripts/gaia-tool.sh | cut -f2)"
  [ "$owner" = fixture-shell ] || { echo "owner: $owner" >&2; return 1; }
}

@test "disarm: no jq on PATH" {
  release_skip_branch "$FIXTURE" release
  local bin="$BATS_TEST_TMPDIR/no-jq-bin" tool
  mkdir -p "$bin"
  for tool in git awk sed cat tr sort grep head cut; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done
  export INNER_PATH="$bin"
  run disarmed_and_over_reviews "$LIBRARY_DIRECTORY" "$FIXTURE" "$FIXTURE/.gaia/audit-ci.yml" no-jq
  [ "$status" -eq 0 ]
}

@test "disarm: an unparseable head manifest" {
  release_skip_branch "$FIXTURE" release
  printf '{ "files": \n' > "$FIXTURE/.gaia/manifest.json"
  git -C "$FIXTURE" commit -qam "break the manifest"
  disarmed_and_over_reviews "$LIBRARY_DIRECTORY" "$FIXTURE" "$FIXTURE/.gaia/audit-ci.yml" manifest-unreadable
}

# version_absent_at_base: a fixture whose base has no .gaia/VERSION and whose
# branch adds one.
version_absent_at_base() {
  git -C "$FIXTURE" rm -q .gaia/VERSION
  git -C "$FIXTURE" commit -qm "no version at base"
  git -C "$FIXTURE" checkout -q -b adds-version main
  printf '1.1.0\n' > "$FIXTURE/.gaia/VERSION"
  printf 'echo updated\n' > "$FIXTURE/.gaia/scripts/gaia-tool.sh"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -qm "add version"
}

@test "disarm: .gaia/VERSION absent at the merge base" {
  version_absent_at_base
  disarmed_and_over_reviews "$LIBRARY_DIRECTORY" "$FIXTURE" "$FIXTURE/.gaia/audit-ci.yml" no-version-change
}

@test "the VERSION disarm check fails against a library that ignores the VERSION condition" {
  version_absent_at_base
  local scratch="$BATS_TEST_TMPDIR/ignores-version"
  mkdir -p "$scratch"
  cp "$LIBRARY_DIRECTORY/audit-scope.sh" "$scratch/"
  sed 's/^  if \[ -z "\$base_version" \] .*then$/  if false; then/' "$LIBRARY_DIRECTORY/audit-scope-release.sh" > "$scratch/audit-scope-release.sh"
  grep -q '^  if false; then$' "$scratch/audit-scope-release.sh"
  run disarmed_and_over_reviews "$scratch" "$FIXTURE" "$FIXTURE/.gaia/audit-ci.yml" no-version-change
  [ "$status" -ne 0 ]
}

@test "disarm: a bare tree id head with no merge base" {
  release_skip_branch "$FIXTURE" release
  disarmed_and_over_reviews "$LIBRARY_DIRECTORY" "$FIXTURE" "$FIXTURE/.gaia/audit-ci.yml" no-merge-base "$(git -C "$FIXTURE" rev-parse 'HEAD^{tree}')"
}

@test "a bare tree id head with the merge base supplied arms exactly as HEAD does" {
  release_skip_branch "$FIXTURE" release
  local tree merge_base
  tree="$(git -C "$FIXTURE" rev-parse 'HEAD^{tree}')"
  merge_base="$(git -C "$FIXTURE" merge-base main HEAD)"
  [ "$(state_with "$LIBRARY_DIRECTORY" "$FIXTURE" "$FIXTURE/.gaia/audit-ci.yml" "$tree" "$merge_base")" = "armed 5" ]
  [ "$(owners_with "$LIBRARY_DIRECTORY" "$FIXTURE" "$FIXTURE/.gaia/audit-ci.yml" "$tree" "$merge_base" .gaia/scripts/gaia-tool.sh | cut -f2)" = fixture-scripts ]
}

@test "disarm: no keyed member on the roster" {
  release_skip_branch "$FIXTURE" release
  [ "$(state_with "$LIBRARY_DIRECTORY" "$FIXTURE" "$WITHOUT_KEYED")" = "disarmed no-skip-member" ]
  [ "$(owner_without_keyed .gaia/scripts/gaia-tool.sh)" = fixture-scripts ]
}

@test "a re-init disarms a context an earlier call armed" {
  release_skip_branch "$FIXTURE" release
  run bash -c '
    . "$1/audit-scope.sh"
    audit_scope_init "$2" && audit_scope_release_context "$2" main
    audit_scope_release_context_state
    audit_scope_init "$2"
    audit_scope_release_context_state
    audit_owner_for_path .gaia/scripts/gaia-tool.sh
  ' _ "$LIBRARY_DIRECTORY" "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines_of 'armed 5' 'disarmed not-requested' fixture-shell)" ]
}

@test "a copy of the classifier without its release sibling routes as before and never arms" {
  release_skip_branch "$FIXTURE" release
  local scratch="$BATS_TEST_TMPDIR/lone-classifier"
  mkdir -p "$scratch"
  cp "$LIBRARY_DIRECTORY/audit-scope.sh" "$scratch/"
  run bash -c '
    . "$1/audit-scope.sh"
    audit_scope_init "$2" || exit 9
    audit_scope_release_context "$2" main
    audit_owner_for_path .gaia/scripts/gaia-tool.sh
  ' _ "$scratch" "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = fixture-shell ]
}

# ---------- digest and resolver agree ------------------------------------------

# digest_members <library-directory> <target>: members whose branch-own digest
# differs from fixture-idle's, whose frame holds only machinery; sorted.
digest_members() {
  local merge_base lines idle
  merge_base="$(git -C "$FIXTURE" merge-base main HEAD)"
  lines="$(bash -c '. "$1/audit-digest.sh"; audit_branch_digests_all "$2" "$3" "$4"' _ "$1" "$FIXTURE" "$merge_base" "$2")" || return 1
  idle="$(printf '%s\n' "$lines" | awk -F'\t' '$1 == "fixture-idle" { print $2 }')"
  [ -n "$idle" ] || return 1
  printf '%s\n' "$lines" | awk -F'\t' -v idle="$idle" '$2 != idle { print $1 }' | LC_ALL=C sort
}

# digest_matches_resolver <library-directory>: the digest's member set equals
# the resolver's, for the HEAD target and for HEAD's bare tree id.
digest_matches_resolver() {
  local resolved by_head by_tree
  resolved="$(resolve_members)"
  by_head="$(digest_members "$1" HEAD)" || return 1
  by_tree="$(digest_members "$1" "$(git -C "$FIXTURE" rev-parse 'HEAD^{tree}')")" || return 1
  [ -n "$resolved" ] || return 1
  [ "$by_head" = "$resolved" ] || { echo "head digest set: $by_head; resolver: $resolved" >&2; return 1; }
  [ "$by_tree" = "$by_head" ] || { echo "tree digest set: $by_tree; head: $by_head" >&2; return 1; }
}

# mutated_digest_library <name> <sed-expression>: a scratch copy of the hook
# libraries whose audit-digest.sh carries the edit; prints its directory.
mutated_digest_library() {
  local scratch="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$scratch/.claude/hooks/lib" "$scratch/.gaia/scripts"
  cp "$LIBRARY_DIRECTORY"/*.sh "$scratch/.claude/hooks/lib/"
  cp "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh" "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$scratch/.gaia/scripts/"
  sed "$2" "$LIBRARY_DIRECTORY/audit-digest.sh" > "$scratch/.claude/hooks/lib/audit-digest.sh"
  cmp -s "$LIBRARY_DIRECTORY/audit-digest.sh" "$scratch/.claude/hooks/lib/audit-digest.sh" && return 1
  printf '%s' "$scratch/.claude/hooks/lib"
}

@test "digest and resolver agree on a release branch, for HEAD and for its tree id" {
  release_skip_branch "$FIXTURE" release
  digest_matches_resolver "$LIBRARY_DIRECTORY"
}

@test "digest and resolver agree on an ordinary branch, for HEAD and for its tree id" {
  release_skip_branch "$FIXTURE" ordinary
  digest_matches_resolver "$LIBRARY_DIRECTORY"
}

@test "the agreement check fails against a digest that never arms the context" {
  release_skip_branch "$FIXTURE" release
  local library
  library="$(mutated_digest_library no-context '/audit_scope_release_context "\$root"/d')"
  run digest_matches_resolver "$library"
  [ "$status" -ne 0 ]
  [[ "$output" == *"head digest set"* ]] || return 1
}

@test "the agreement check fails against a digest that omits the merge base for a tree id" {
  release_skip_branch "$FIXTURE" release
  local library
  library="$(mutated_digest_library no-merge-base-argument 's/"\$target" "\$merge_base"$/"$target"/')"
  run digest_matches_resolver "$library"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tree digest set"* ]] || return 1
}

# ---------- every branch-diff consumer arms the context ------------------------

# Digest-only callers: their classification happens inside audit-digest.sh,
# which arms itself. resolve-audit-base.sh's only classifier reference is a
# presence probe.
DIGEST_ONLY_CALLERS='.claude/hooks/post-audit-status.sh
.gaia/scripts/audit-fix-verify.sh
.gaia/scripts/audit-member-digest.sh
.gaia/scripts/audit-scope-digest.sh
.gaia/scripts/audit-write-clearance.sh
.github/audit/resolve-audit-base.sh'
# By design: verify-audit-roster.sh classifies the whole tree with no diff, and
# audit-dispositions-check.sh asks ownership only for triage marks, which only
# the maintainer members write.
EXEMPT_CONSUMERS='.gaia/scripts/verify-audit-roster.sh
.gaia/scripts/audit-dispositions-check.sh'

# _non_comment_mentions <file> <extended-regex>: exit 0 when a non-comment line
# names the pattern.
_non_comment_mentions() {
  grep -vE '^[[:space:]]*#' "$1" | grep -qE "$2"
}

# release_context_violations <root>: prints each consumer that neither arms the
# context nor is a named exemption, and each named exemption that no longer
# exists or no longer calls the classifier. Non-empty output is a failure.
release_context_violations() {
  local root="$1" call_pattern='audit_scope_init|audit_owner_for_path|audit_owners_for_paths|audit_branch_digests_[A-Za-z_]+' file consumers="" listed
  while IFS= read -r -d '' file; do
    case "$file" in
      .gaia/tests/*|*/tests/*|.claude/hooks/lib/audit-scope.sh|.claude/hooks/lib/audit-scope-release.sh) continue ;;
    esac
    [ -f "$root/$file" ] || continue
    _non_comment_mentions "$root/$file" "$call_pattern" || continue
    consumers="${consumers}${file}"$'\n'
    _non_comment_mentions "$root/$file" 'audit_scope_release_context' && continue
    printf '%s\n%s\n' "$DIGEST_ONLY_CALLERS" "$EXEMPT_CONSUMERS" | grep -Fxq -- "$file" && continue
    printf 'unarmed consumer: %s\n' "$file"
  done < <(git -C "$root" ls-files -z --cached --others --exclude-standard -- '*.sh')
  [ -n "$consumers" ] || printf 'no consumer found\n'
  while IFS= read -r listed; do
    printf '%s' "$consumers" | grep -Fxq -- "$listed" || printf 'stale exemption: %s\n' "$listed"
  done < <(printf '%s\n%s\n' "$DIGEST_ONLY_CALLERS" "$EXEMPT_CONSUMERS")
}

# bats test_tags=whole-tree
@test "every consumer that classifies a branch diff arms the release context, or is a named exemption" {
  run release_context_violations "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
  # The arming consumers are present in the enumeration.
  local file
  for file in .gaia/scripts/resolve-audit-members.sh .claude/hooks/lib/audit-digest.sh .claude/hooks/pr-merge-audit-check.sh \
    .gaia/scripts/audit-light-route.sh .gaia/scripts/audit-resolve-scope.sh; do
    _non_comment_mentions "$REPO_ROOT/$file" 'audit_scope_release_context'
  done
}

# bats test_tags=whole-tree
@test "the consumer guard fails on a tree where one consumer's context call is removed" {
  local scratch="$BATS_TEST_TMPDIR/guard-tree" file
  mkdir -p "$scratch"
  git -C "$scratch" init -q
  while IFS= read -r -d '' file; do
    case "$file" in .gaia/tests/*|*/tests/*) continue ;; esac
    mkdir -p "$scratch/$(dirname "$file")"
    cp "$REPO_ROOT/$file" "$scratch/$file"
  done < <(git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard -- '*.sh')
  git -C "$scratch" add -A
  run release_context_violations "$scratch"
  [ -z "$output" ]
  sed '/^audit_scope_release_context /d' "$REPO_ROOT/.gaia/scripts/resolve-audit-members.sh" > "$scratch/.gaia/scripts/resolve-audit-members.sh"
  run release_context_violations "$scratch"
  [ "$output" = "unarmed consumer: .gaia/scripts/resolve-audit-members.sh" ]
  rm "$scratch/.gaia/scripts/audit-dispositions-check.sh"
  run release_context_violations "$scratch"
  [[ "$output" == *"stale exemption: .gaia/scripts/audit-dispositions-check.sh"* ]] || return 1
}

# ---------- no process per path --------------------------------------------------

@test "classifying with the context armed spawns no process per path" {
  release_skip_branch "$FIXTURE" release
  local shim="$BATS_TEST_TMPDIR/shim" log="$BATS_TEST_TMPDIR/spawn.log" tool paths_file="$BATS_TEST_TMPDIR/paths" index=0
  mkdir -p "$shim"
  for tool in git jq awk sed grep sort cat; do
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexec "%s" "$@"\n' "$tool" "$log" "$(command -v "$tool")" > "$shim/$tool"
    chmod +x "$shim/$tool"
  done
  : > "$paths_file"
  while [ "$index" -lt 500 ]; do
    printf '.gaia/scripts/generated-%s.sh\n' "$index" >> "$paths_file"
    index=$((index + 1))
  done
  printf '.gaia/scripts/gaia-tool.sh\n' >> "$paths_file"
  run bash -c '
    . "$1/audit-scope.sh"
    audit_scope_init "$2" && audit_scope_release_context "$2" main
    audit_scope_release_context_state
    : > "$4"
    PATH="$5:$PATH"
    audit_owners_for_paths < "$3" > "$3.owners"
    PATH="${PATH#*:}"
    wc -l < "$4" | tr -d " "
    wc -l < "$3.owners" | tr -d " "
    tail -n 1 "$3.owners"
  ' _ "$LIBRARY_DIRECTORY" "$FIXTURE" "$paths_file" "$log" "$shim"
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines_of 'armed 5' 0 501 "$(printf '.gaia/scripts/gaia-tool.sh\tfixture-scripts')")" ]
}
