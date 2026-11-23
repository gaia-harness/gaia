#!/usr/bin/env bats
# Tests for .github/forensics/check-scope.sh
#
# Covers every allowlist hit, every denylist hit, the default-deny case,
# the allowlist-subtraction edge case, and multi-path partitioning.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../check-scope.sh"
  [ -x "$SCRIPT" ]
}

# expect_scope <label> <expected-json> <path>...
# Prints the case label, runs the script and fails naming the case when the
# exit status is not 0 or the report differs from the expected JSON.
expect_scope() {
  local label=$1 expected=$2
  shift 2
  echo "case: $label"
  run "$SCRIPT" "$@"
  [ "$status" -eq 0 ] || { printf 'case %s: status %s\n' "$label" "$status" >&2; return 1; }
  [ "$output" = "$expected" ] || {
    printf 'case %s: unexpected output: %s\n' "$label" "$output" >&2
    return 1
  }
}

# expect_allow <label> <path>: the path is allowed on its own.
expect_allow() {
  expect_scope "$1" "{\"ok\":true,\"allowed\":[\"$2\"],\"denied\":[]}" "$2"
}

# expect_deny <label> <path> <reason>: the path is denied with that reason.
expect_deny() {
  expect_scope "$1" "{\"ok\":false,\"allowed\":[],\"denied\":[{\"path\":\"$2\",\"reason\":\"$3\"}]}" "$2"
}

# expect_reject <label> <glob> <path>...: exit 0 and the report matches the
# glob. The glob holds no bracket, so it never reads as a character class.
expect_reject() {
  local label=$1 pattern=$2
  shift 2
  echo "case: $label"
  run "$SCRIPT" "$@"
  [ "$status" -eq 0 ] || { printf 'case %s: status %s\n' "$label" "$status" >&2; return 1; }
  # shellcheck disable=SC2254 # the pattern is a deliberate glob
  case $output in
    $pattern) ;;
    *) printf 'case %s: unexpected output: %s\n' "$label" "$output" >&2; return 1 ;;
  esac
}

# --- exit-code and zero-input contract ----------------------------------------

@test "exit code is always 0 and no args gives an empty ok report (case table)" {
  echo "case: exit code is always 0 (consumer reads ok from JSON)"
  run "$SCRIPT" apps/web/app/foo.ts
  [ "$status" -eq 0 ]
  run "$SCRIPT" .gaia/cli/foo.sh
  [ "$status" -eq 0 ]
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  expect_scope "no args: ok:true with empty arrays" '{"ok":true,"allowed":[],"denied":[]}'
}

# --- allowlist hits --------------------------------------------------------

@test "allowlist: each allowed prefix and exact file is allowed (case table)" {
  expect_allow "allowlist: .gaia/cli/" .gaia/cli/foo.sh
  expect_allow "allowlist: .claude/skills/" .claude/skills/foo/SKILL.md
  expect_allow "allowlist: .claude/commands/" .claude/commands/gaia.md
  expect_allow "allowlist: .claude/agents/" .claude/agents/code-review-audit.md
  expect_allow "allowlist: .gaia/scripts/spec/" .gaia/scripts/spec/foo.sh
  expect_allow "allowlist: .gaia/manifest.json (exact file)" .gaia/manifest.json
  expect_allow "allowlist: .gaia/cli/src/ stays editable beside the denied bundles" .gaia/cli/src/index.ts
}

# --- denylist hits ---------------------------------------------------------
# Claude Code hooks, the statusline, git hooks and the CLI bundles they call
# run on their own once a branch is checked out locally, so a bot-authored
# branch must never carry an edit to them. A file-level deny under an allowed
# prefix overrides the parent allowlist (UAT-007).

# bats test_tags=protected
@test "denylist: each denied directory, file and bundle is denied, including the file-level override of an allowed prefix (case table)" {
  expect_deny "denylist: apps/web/app/" apps/web/app/foo.ts denylist
  expect_deny "denylist: wiki/" wiki/index.md denylist
  expect_deny "denylist: studio/" studio/branding/IDENTITY.md denylist
  expect_deny "denylist: website/" website/src/sections/Hero.tsx denylist
  expect_deny "denylist: .notebook/ specs" .notebook/specs/SPEC-002/SPEC.md denylist
  expect_deny "denylist: .notebook/ research" .notebook/research/x/README.md denylist
  expect_deny "denylist: .github/workflows/" .github/workflows/forensics-triage.yml denylist
  expect_deny "denylist: .claude/hooks/ (Claude Code runs these on every tool call)" .claude/hooks/post-commit.sh denylist
  expect_deny "denylist: .claude/hooks/lib/ (sourced by the hooks)" .claude/hooks/lib/cross-repo-refusal.sh denylist
  expect_deny "denylist: .gaia/statusline/ (refreshed by the statusline on a timer)" .gaia/statusline/gaia-statusline.sh denylist
  expect_deny "denylist: .githooks/ (git runs these on commit and push)" .githooks/pre-commit denylist
  expect_deny "denylist: .claude/settings.json (registers the hooks and statusline)" .claude/settings.json denylist
  expect_deny "denylist: .claude/settings.local.json" .claude/settings.local.json denylist
  expect_deny "denylist: .gaia/cli/gaia bundle overrides the .gaia/cli/ allowlist" .gaia/cli/gaia denylist
  expect_deny "denylist: .gaia/cli/gaia-maintainer bundle overrides the .gaia/cli/ allowlist" .gaia/cli/gaia-maintainer denylist
  expect_deny "subtraction: a file-level deny under .claude/skills/ overrides the parent allowlist" .claude/skills/gaia/references/spec/spec-template.md denylist
}

# --- install-time manifests -------------------------------------------------
# pnpm runs lifecycle scripts from every workspace member's manifest, and
# reads hooks and settings from the workspace and pnpmfile, so these deny by
# file name at any depth, under any allowlisted prefix.

# bats test_tags=protected
@test "manifest names are denied at any depth under any prefix, a name merely ending in package.json stays allowed (case table)" {
  expect_deny "manifest: .gaia/cli/package.json is denied under the .gaia/cli/ allowlist" .gaia/cli/package.json denylist
  expect_deny "manifest: a package.json nested under an allowlisted prefix is denied" .claude/skills/foo/package.json denylist
  for name in pnpm-workspace.yaml pnpm-lock.yaml .npmrc .pnpmfile.cjs .pnpmfile.mjs; do
    expect_deny "manifest: pnpm workspace, lockfile, npmrc and pnpmfile names are denied at any depth ($name)" "$name" denylist
    expect_deny "manifest: pnpm workspace, lockfile, npmrc and pnpmfile names are denied at any depth (.gaia/cli/$name)" ".gaia/cli/$name" denylist
  done
  expect_allow "manifest: a file name that only ends in package.json stays allowed" .gaia/cli/src/not-package.json
  expect_deny "manifest: root package.json is denylisted" package.json denylist
}

# bats test_tags=protected
@test "manifest: every pnpm workspace member's package.json is denied" {
  # Derived from pnpm-workspace.yaml, so a new member is covered without an
  # edit here; the root manifest is listed beside them.
  workspace_file="${BATS_TEST_DIRNAME}/../../../pnpm-workspace.yaml"
  members=()
  while IFS= read -r member; do
    members+=("$member/package.json")
  done < <(awk '/^packages:/{in_list=1; next} in_list && /^[[:space:]]*-/{sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/["'\'']/, ""); print; next} in_list && !/^[[:space:]]*$/{in_list=0}' "$workspace_file")
  [ "${#members[@]}" -ge 2 ]
  for manifest in package.json "${members[@]}"; do
    run "$SCRIPT" "$manifest"
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.denied[0].reason')" = "denylist" ]
  done
}

# --- default-deny (UAT-014) ------------------------------------------------

# bats test_tags=protected
@test "default-deny: an unenumerated path is denied (case table)" {
  expect_deny "retired root app/ is no longer denylisted (default-deny, not allowed)" app/foo.ts default-deny-unenumerated
  expect_deny "default-deny: eslint.config.ts" eslint.config.ts default-deny-unenumerated
  # `.gaia/cliques/` is NOT `.gaia/cli/`; trailing-slash discipline prevents
  # bleed.
  expect_deny "default-deny: sibling of an allowlist prefix does not match" .gaia/cliques/foo.sh default-deny-unenumerated
  # Defensive: git diff names files, never bare directories. A bare
  # ".gaia/cli" does not match the ".gaia/cli/" prefix.
  expect_deny "default-deny: bare directory name without trailing path" .gaia/cli default-deny-unenumerated
}

# --- multi-path partitioning -----------------------------------------------

# bats test_tags=protected
@test "multi-path input is partitioned into allowed and denied with per-path reasons (case table)" {
  expect_scope "multi: all-allow → ok:true" \
    '{"ok":true,"allowed":[".gaia/cli/foo.sh",".claude/skills/bar/SKILL.md",".gaia/manifest.json"],"denied":[]}' \
    .gaia/cli/foo.sh .claude/skills/bar/SKILL.md .gaia/manifest.json
  expect_scope "multi: any-deny flips ok:false; allowed/denied partition the input" \
    '{"ok":false,"allowed":[".gaia/cli/foo.sh"],"denied":[{"path":"apps/web/app/bar.ts","reason":"denylist"},{"path":"eslint.config.ts","reason":"default-deny-unenumerated"}]}' \
    .gaia/cli/foo.sh apps/web/app/bar.ts eslint.config.ts
  expect_scope "multi: deny reasons are recorded per-path (mixed denylist + default-deny)" \
    '{"ok":false,"allowed":[],"denied":[{"path":"wiki/foo.md","reason":"denylist"},{"path":"eslint.config.ts","reason":"default-deny-unenumerated"}]}' \
    wiki/foo.md eslint.config.ts
}

# --- control-byte rejection (UAT-009) --------------------------------------
#
# JSON forbids unescaped U+0000..U+001F inside string literals. The script
# rejects any path containing a control byte with a structured error
# envelope rather than emitting malformed JSON. Filesystems forbid these
# in path names in practice; the rejection path defends against synthetic
# inputs (misbehaving callers, future test harnesses) and surfaces them
# as an explicit upstream signal.

# bats test_tags=protected
@test "a control byte denies the whole invocation with a structured envelope (case table)" {
  expect_reject "control-byte: tab (0x09) → reject with reason naming hex+position" \
    '*"ok":false*"reason":"control-byte:0x09-at-position-7"*' "$(printf 'app/foo\tbar.ts')"
  expect_reject "control-byte: newline (0x0a) → reject with reason naming hex+position" \
    '*"ok":false*"reason":"control-byte:0x0a-at-position-10"*' "$(printf 'wiki/index\nmd')"
  expect_reject "control-byte: carriage-return (0x0d) → reject" \
    '*"reason":"control-byte:0x0d-at-position-1"*' "$(printf 'a\rb')"
  expect_reject "control-byte: U+0001 (SOH, 0x01) → reject" \
    '*"reason":"control-byte:0x01-at-position-3"*' "$(printf 'foo\001bar')"
  # Whole envelope: allowed must be empty and denied must hold exactly the one entry.
  expect_scope "control-byte: rejection envelope shape, ok:false, allowed:[], single denied entry" \
    '{"ok":false,"allowed":[],"denied":[{"path":"x?y","reason":"control-byte:0x09-at-position-1"}]}' "$(printf 'x\ty')"

  # The remaining args (allow + deny) must not appear in the output: the
  # rejection envelope replaces the normal classification result.
  echo "case: control-byte: short-circuits before classifying remaining paths"
  run "$SCRIPT" "$(printf 'bad\tpath')" .gaia/cli/foo.sh app/bar.ts
  [ "$status" -eq 0 ]
  case $output in
    *'.gaia/cli/foo.sh'*) printf 'allowlisted path leaked: %s\n' "$output" >&2; return 1 ;;
    *'app/bar.ts'*) printf 'denylisted path leaked: %s\n' "$output" >&2; return 1 ;;
    *'"reason":"control-byte:0x09-at-position-3"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

# --- path-traversal rejection (RT-05) --------------------------------------
#
# classify_path does pure prefix matching, so an unnormalized `..` segment
# lets a path start under an allowlist prefix yet resolve outside the
# sandbox. Any candidate carrying a `..` PATH SEGMENT is rejected before
# classification, mirroring the control-byte short-circuit: first offending
# path wins and denies the whole invocation. A `..` substring that is not a
# path segment (e.g. `foo..bar`) is NOT a traversal and must classify
# normally.

# bats test_tags=protected
@test "a .. path segment denies the whole invocation, a mere .. substring does not (case table)" {
  traversal='path-traversal:contains-..-segment'
  for case_path in '.claude/skills/../../.github/workflows/x.yml' '.gaia/cli/../manifest.json' '../etc/passwd' '.gaia/cli/..'; do
    case $case_path in
      .claude/skills/*) label="traversal: .. segment escapes allowlist prefix → reject" ;;
      .gaia/cli/../*) label="traversal: .. segment mid-path → reject" ;;
      ../*) label="traversal: leading ../ → reject" ;;
      *) label="traversal: trailing /.. → reject" ;;
    esac
    expect_scope "$label" "{\"ok\":false,\"allowed\":[],\"denied\":[{\"path\":\"$case_path\",\"reason\":\"$traversal\"}]}" "$case_path"
  done
  # `.gaia/cli/foo.d.ts` has dots but no `..` path segment; classifies as allow.
  expect_allow "traversal: dotted filename without .. segment is unaffected" '.gaia/cli/foo.d.ts'
  # `foo..bar.ts` contains the `..` substring but not as a bounded segment;
  # the guard must not false-positive on it.
  expect_allow "traversal: .. substring that is not a path segment is unaffected" '.gaia/cli/foo..bar.ts'

  echo "case: traversal: first offending path denies the whole invocation"
  run "$SCRIPT" '.gaia/cli/../x' .gaia/cli/foo.sh app/bar.ts
  [ "$status" -eq 0 ]
  case $output in
    *'.gaia/cli/foo.sh'*) printf 'allowlisted path leaked: %s\n' "$output" >&2; return 1 ;;
    *'app/bar.ts'*) printf 'denylisted path leaked: %s\n' "$output" >&2; return 1 ;;
    *'"reason":"path-traversal:contains-..-segment"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

# --- case-variant deny (case-insensitive checkouts) ------------------------

# bats test_tags=protected
@test "a case variant of a denied name is denied (case table)" {
  expect_deny "denylist: case variant of a denied file under an allowed prefix (.gaia/cli/GAIA)" .gaia/cli/GAIA denylist
  expect_deny "denylist: case variant of a denied name under an allowed prefix (.gaia/cli/Package.json)" .gaia/cli/Package.json denylist
}

# --- non-ASCII lookalikes ---------------------------------------------------

# bats test_tags=protected
@test "a non-ASCII byte in a path is denied (case table)" {
  echo "case: non-ascii: a Kelvin-sign lookalike of a denied name is denied under LC_ALL=C"
  path=$(printf '.gaia/cli/pac\xe2\x84\xaage.json')
  LC_ALL=C run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  case $output in
    *'"ok":false'*'"reason":"non-ascii-path"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
  expect_reject "non-ascii: an otherwise allowed path with a non-ASCII byte is denied" \
    '*"ok":false*"reason":"non-ascii-path"*' "$(printf '.claude/skills/caf\xc3\xa9.md')"
}

# --- rename-aware scope re-checks -------------------------------------------

@test "workflow: every changed-path-listing diff carries --no-renames" {
  workflow="${BATS_TEST_DIRNAME}/../../workflows/forensics-triage.yml"
  [ -f "$workflow" ]
  # Assembled at run time so this file never spells the listing flag itself.
  listing_flag='--name-'"only"
  total=0
  bare=0
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      *--no-renames*) ;;
      *) bare=$((bare + 1)) ;;
    esac
  done < <(grep -E "git diff .*${listing_flag}" "$workflow")
  # Both scope re-checks (triage verify-diff, quality-gate) must be present.
  [ "$total" -ge 2 ]
  [ "$bare" -eq 0 ]
}

# --- workflow step scripts ---------------------------------------------------

# bats test_tags=whole-tree
@test "workflow: the steps/ scripts and the workflow's calls to them are the same set, all executable" {
  workflow="${BATS_TEST_DIRNAME}/../../workflows/forensics-triage.yml"
  steps_dir="${BATS_TEST_DIRNAME}/../steps"
  [ -f "$workflow" ]
  on_disk=$(cd "$steps_dir" && ls -1 -- *.sh | sort)
  called=$(grep -oE '"\$FORENSICS_DIR/steps/[a-z0-9-]+\.sh"' "$workflow" | sed -E 's|.*/steps/||; s|"$||' | sort -u)
  [ -n "$on_disk" ]
  [ "$on_disk" = "$called" ]
  while IFS= read -r script; do
    [ -x "$steps_dir/$script" ] || { printf 'not executable: %s\n' "$script" >&2; return 1; }
  done <<<"$on_disk"
}
