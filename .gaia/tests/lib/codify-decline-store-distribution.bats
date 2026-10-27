#!/usr/bin/env bats
# The committed /gaia-codify decline store, `.gaia/codify-declines/`, is the
# adopter's own data: GAIA never ships its declines, `/update-gaia` never
# overwrites, prunes or flags them, and a pull request that only adds a decline
# file owes no Code Audit Team member.
#
# Each property is a helper that returns non-zero on a violation. A real-tree
# case proves the helper passes, and a mutation case drives a scratch copy into
# the failing state and asserts the helper refuses, so no guard here can pass
# vacuously. Scratch repositories live under $BATS_TEST_TMPDIR; the real
# checkout's index, HEAD and working tree are never touched.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup_file() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  export REPO_ROOT
  export DECLINE_FOLDER=".gaia/codify-declines"
  export DECLINE_FILE_NAME="rule-x-20261027-000000000-0a1b2c3d.json"
}

# Clone the committed HEAD into $1 with a pinned identity.
clone_repository() {
  git clone --quiet --local "$REPO_ROOT" "$1" || return 1
  git -C "$1" config user.name "Scratch Tester"
  git -C "$1" config user.email "scratch@example.com"
}

# Stage everything in clone $1 and record it as one revision titled $2.
record_revision() {
  git -C "$1" add -A || return 1
  git -C "$1" commit --quiet -m "$2"
}

# Write one valid version-1 decline file into clone $1 and print its relative path.
write_decline_file() {
  local clone="$1" relative_path="$DECLINE_FOLDER/$DECLINE_FILE_NAME"
  mkdir -p "$clone/$DECLINE_FOLDER"
  cat > "$clone/$relative_path" <<'JSON'
{
  "format_version": 1,
  "finding_class": "rule/x",
  "declined_at": "2026-10-27T00:00:00.000Z",
  "declined_at_pr_count": 4,
  "declined_at_audited_pr_count": 40,
  "tally_schema_version": 4
}
JSON
  printf '%s\n' "$relative_path"
}

# --- Property 1: release-exclude ----------------------------------------------

# assert_release_exclude_lists_folder <release-exclude file>
assert_release_exclude_lists_folder() {
  grep -qxF -- "$DECLINE_FOLDER" "$1" || {
    echo "release-exclude does not list $DECLINE_FOLDER: $1" >&2
    return 1
  }
}

# --- Property 3: release-scrub ref opt-out --------------------------------------

# Print the entries of the `ref-opt-out:` list, comments stripped, one per line.
ref_opt_out_entries() {
  awk '
    /^[[:space:]]*ref-opt-out:[[:space:]]*$/ { in_block = 1; next }
    in_block && /^[[:space:]]*-[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      gsub(/^"|"$/, "", line)
      print line
      next
    }
    in_block && /^[[:space:]]*#/ { next }
    in_block { in_block = 0 }
  ' "$1"
}

# assert_scrub_opts_out_folder <release-scrub file>
assert_scrub_opts_out_folder() {
  local entries
  entries="$(ref_opt_out_entries "$1")"
  [ -n "$entries" ] || { echo "no ref-opt-out entries read from $1" >&2; return 1; }
  grep -qxF -- "$DECLINE_FOLDER" <<<"$entries" || {
    echo "ref-opt-out does not list $DECLINE_FOLDER: $1" >&2
    return 1
  }
}

# --- Property 2: manifest absence while a decline file is committed -------------

# assert_manifest_omits_decline_files <clone>
# One manifest generation per call. Refuses when the check fails or the
# generated manifest lists any path under the decline folder.
assert_manifest_omits_decline_files() {
  local clone="$1" listed
  ( cd "$clone" && ./.gaia/cli/gaia-maintainer release manifest --check ) \
    > "$BATS_TEST_TMPDIR/manifest-check.out" 2>&1 || {
    echo "release manifest --check failed:" >&2
    cat "$BATS_TEST_TMPDIR/manifest-check.out" >&2
    return 1
  }
  listed="$( cd "$clone" && ./.gaia/cli/gaia-maintainer release manifest --stdout --allow-undecided \
    | jq -r '.files | keys[]' | grep -F -- "$DECLINE_FOLDER/" )" || true
  [ -z "$listed" ] || {
    echo "manifest lists decline paths: $listed" >&2
    return 1
  }
}

# --- Property 4: a decline-only diff owes no member -----------------------------

# assert_no_member_owed <clone> <base sha>: refuses on a non-zero exit or any stdout.
assert_no_member_owed() {
  local clone="$1" base="$2" members
  members="$(bash "$clone/.gaia/scripts/resolve-audit-members.sh" --root "$clone" --base "$base")" || {
    echo "resolve-audit-members.sh exited non-zero" >&2
    return 1
  }
  [ -z "$members" ] || {
    echo "members owed for a decline-only diff: $members" >&2
    return 1
  }
}

# Add the decline folder glob to the code-audit-maintainer-shell member's globs.
grant_folder_to_shell_member() {
  local roster="$1/.gaia/audit-ci.yml"
  awk -v folder="$DECLINE_FOLDER/**" '
    /^[[:space:]]*-[[:space:]]+name:[[:space:]]+code-audit-maintainer-shell[[:space:]]*$/ { in_member = 1 }
    in_member && /^[[:space:]]*globs:[[:space:]]*$/ {
      print
      printf "      - \"%s\"\n", folder
      in_member = 0
      next
    }
    { print }
  ' "$roster" > "$roster.new" && mv "$roster.new" "$roster"
  grep -qF -- "\"$DECLINE_FOLDER/**\"" "$roster"
}

# --- Tests ----------------------------------------------------------------------

@test "release-exclude lists the decline folder" {
  assert_release_exclude_lists_folder "$REPO_ROOT/.gaia/release-exclude"
}

@test "release-exclude check refuses a copy without the decline folder line" {
  grep -vxF -- "$DECLINE_FOLDER" "$REPO_ROOT/.gaia/release-exclude" > "$BATS_TEST_TMPDIR/release-exclude" || true
  run assert_release_exclude_lists_folder "$BATS_TEST_TMPDIR/release-exclude"
  [ "$status" -ne 0 ] || return 1
}

# Slow: one manifest generation per scratch clone.
# bats test_tags=whole-tree
@test "a committed decline file stays out of the release manifest" {
  local clone="$BATS_TEST_TMPDIR/clone"
  clone_repository "$clone" || return 1
  write_decline_file "$clone" > /dev/null
  record_revision "$clone" "add a decline file" || return 1
  assert_manifest_omits_decline_files "$clone"
}

# Slow: one manifest generation per scratch clone.
# bats test_tags=whole-tree
@test "manifest check refuses once the release-exclude line is gone" {
  local clone="$BATS_TEST_TMPDIR/clone"
  clone_repository "$clone" || return 1
  write_decline_file "$clone" > /dev/null
  grep -vxF -- "$DECLINE_FOLDER" "$clone/.gaia/release-exclude" > "$clone/.gaia/release-exclude.new" || true
  mv "$clone/.gaia/release-exclude.new" "$clone/.gaia/release-exclude"
  record_revision "$clone" "add a decline file without the exclusion" || return 1
  run assert_manifest_omits_decline_files "$clone"
  [ "$status" -ne 0 ] || return 1
}

@test "release-scrub opts the decline folder out of the excluded-refs check" {
  assert_scrub_opts_out_folder "$REPO_ROOT/.gaia/release-scrub.yml"
}

@test "release-scrub check refuses a copy with the ref opt-out entry removed" {
  grep -vF -- "- \"$DECLINE_FOLDER\"" "$REPO_ROOT/.gaia/release-scrub.yml" > "$BATS_TEST_TMPDIR/release-scrub.yml" || true
  grep -qF -- "- \"$DECLINE_FOLDER\"" "$BATS_TEST_TMPDIR/release-scrub.yml" && return 1
  run assert_scrub_opts_out_folder "$BATS_TEST_TMPDIR/release-scrub.yml"
  [ "$status" -ne 0 ] || return 1
}

@test "release-scrub check refuses a copy with the entry moved to another list" {
  awk -v folder="$DECLINE_FOLDER" '
    index($0, "- \"" folder "\"") { next }
    { print }
    /^[[:space:]]*path-allowlist:[[:space:]]*$/ && !moved {
      printf "          - \"%s\"\n", folder
      moved = 1
    }
  ' "$REPO_ROOT/.gaia/release-scrub.yml" > "$BATS_TEST_TMPDIR/release-scrub.yml"
  grep -qF -- "- \"$DECLINE_FOLDER\"" "$BATS_TEST_TMPDIR/release-scrub.yml" || return 1
  run assert_scrub_opts_out_folder "$BATS_TEST_TMPDIR/release-scrub.yml"
  [ "$status" -ne 0 ] || return 1
}

# bats test_tags=whole-tree
@test "a decline-only diff resolves an empty audit member set" {
  local clone="$BATS_TEST_TMPDIR/clone" base
  clone_repository "$clone" || return 1
  base="$(git -C "$clone" rev-parse HEAD)"
  git -C "$clone" checkout --quiet -b decline-only || return 1
  write_decline_file "$clone" > /dev/null
  record_revision "$clone" "add a decline file" || return 1
  assert_no_member_owed "$clone" "$base"
}

# bats test_tags=whole-tree
@test "a roster that owns the decline folder makes the empty-member check refuse" {
  local clone="$BATS_TEST_TMPDIR/clone" base
  clone_repository "$clone" || return 1
  grant_folder_to_shell_member "$clone" || return 1
  record_revision "$clone" "grant the decline folder to the shell member" || return 1
  # The roster edit is the base, so the decline file is the only path in the diff.
  base="$(git -C "$clone" rev-parse HEAD)"
  git -C "$clone" checkout --quiet -b decline-only || return 1
  write_decline_file "$clone" > /dev/null
  record_revision "$clone" "add a decline file" || return 1
  run bash "$clone/.gaia/scripts/resolve-audit-members.sh" --root "$clone" --base "$base"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "code-audit-maintainer-shell" ] || return 1
  run assert_no_member_owed "$clone" "$base"
  [ "$status" -ne 0 ] || return 1
}

# bats test_tags=whole-tree
@test "the same JSON one level up, as a .gaia json file, is owned by the shell member" {
  local clone="$BATS_TEST_TMPDIR/clone" base relative_path
  clone_repository "$clone" || return 1
  base="$(git -C "$clone" rev-parse HEAD)"
  git -C "$clone" checkout --quiet -b flat-file || return 1
  relative_path="$(write_decline_file "$clone")"
  mv "$clone/$relative_path" "$clone/.gaia/codify-declines.json"
  rm -rf "${clone:?}/$DECLINE_FOLDER"
  record_revision "$clone" "add the decline as a flat json file" || return 1
  run bash "$clone/.gaia/scripts/resolve-audit-members.sh" --root "$clone" --base "$base"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "code-audit-maintainer-shell" ] || return 1
}

@test "the out-of-scope bypass allowlists a decline file and not an app source file" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
  audit_out_of_scope_allowlisted "$DECLINE_FOLDER/$DECLINE_FILE_NAME" || return 1
  run audit_out_of_scope_allowlisted frontend/app/x.ts
  [ "$status" -eq 1 ] || return 1
}
