#!/usr/bin/env bats
# Tests for .github/forensics/check-scope.sh
#
# Covers every allowlist hit, every denylist hit, the default-deny case,
# the allowlist-subtraction edge case, and multi-path partitioning.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../check-scope.sh"
  [ -x "$SCRIPT" ]
}

# --- exit-code contract ----------------------------------------------------

@test "exit code is always 0 (consumer reads ok from JSON)" {
  run "$SCRIPT" frontend/app/foo.ts
  [ "$status" -eq 0 ]
  run "$SCRIPT" .gaia/cli/foo.sh
  [ "$status" -eq 0 ]
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# --- allowlist hits --------------------------------------------------------

@test "allowlist: .gaia/cli/" {
  run "$SCRIPT" .gaia/cli/foo.sh
  [ "$output" = '{"ok":true,"allowed":[".gaia/cli/foo.sh"],"denied":[]}' ]
}

@test "allowlist: .claude/skills/" {
  run "$SCRIPT" .claude/skills/foo/SKILL.md
  [ "$output" = '{"ok":true,"allowed":[".claude/skills/foo/SKILL.md"],"denied":[]}' ]
}

@test "allowlist: .claude/commands/" {
  run "$SCRIPT" .claude/commands/gaia.md
  [ "$output" = '{"ok":true,"allowed":[".claude/commands/gaia.md"],"denied":[]}' ]
}

@test "allowlist: .claude/agents/" {
  run "$SCRIPT" .claude/agents/code-review-audit.md
  [ "$output" = '{"ok":true,"allowed":[".claude/agents/code-review-audit.md"],"denied":[]}' ]
}

@test "allowlist: .gaia/scripts/spec/" {
  run "$SCRIPT" .gaia/scripts/spec/foo.sh
  [ "$output" = '{"ok":true,"allowed":[".gaia/scripts/spec/foo.sh"],"denied":[]}' ]
}

@test "allowlist: .gaia/manifest.json (exact file)" {
  run "$SCRIPT" .gaia/manifest.json
  [ "$output" = '{"ok":true,"allowed":[".gaia/manifest.json"],"denied":[]}' ]
}

# --- denylist hits ---------------------------------------------------------

@test "denylist: frontend/app/" {
  run "$SCRIPT" frontend/app/foo.ts
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"frontend/app/foo.ts","reason":"denylist"}]}' ]
}

@test "retired root app/ is no longer denylisted (default-deny, not allowed)" {
  run "$SCRIPT" app/foo.ts
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"app/foo.ts","reason":"default-deny-unenumerated"}]}' ]
}

@test "denylist: wiki/" {
  run "$SCRIPT" wiki/index.md
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"wiki/index.md","reason":"denylist"}]}' ]
}

@test "denylist: studio/" {
  run "$SCRIPT" studio/branding/IDENTITY.md
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"studio/branding/IDENTITY.md","reason":"denylist"}]}' ]
}

@test "denylist: website/" {
  run "$SCRIPT" website/src/sections/Hero.tsx
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"website/src/sections/Hero.tsx","reason":"denylist"}]}' ]
}

@test "denylist: .notebook/ specs" {
  run "$SCRIPT" .notebook/specs/SPEC-002/SPEC.md
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".notebook/specs/SPEC-002/SPEC.md","reason":"denylist"}]}' ]
}

@test "denylist: .notebook/ research" {
  run "$SCRIPT" .notebook/research/x/README.md
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".notebook/research/x/README.md","reason":"denylist"}]}' ]
}

@test "denylist: .github/workflows/" {
  run "$SCRIPT" .github/workflows/forensics-triage.yml
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".github/workflows/forensics-triage.yml","reason":"denylist"}]}' ]
}

# --- auto-executing harness paths ------------------------------------------
# Claude Code hooks, the statusline, git hooks and the CLI bundles they call
# run on their own once a branch is checked out locally, so a bot-authored
# branch must never carry an edit to them.

@test "denylist: .claude/hooks/ (Claude Code runs these on every tool call)" {
  run "$SCRIPT" .claude/hooks/post-commit.sh
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".claude/hooks/post-commit.sh","reason":"denylist"}]}' ]
}

@test "denylist: .claude/hooks/lib/ (sourced by the hooks)" {
  run "$SCRIPT" .claude/hooks/lib/cross-repo-refusal.sh
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".claude/hooks/lib/cross-repo-refusal.sh","reason":"denylist"}]}' ]
}

@test "denylist: .gaia/statusline/ (refreshed by the statusline on a timer)" {
  run "$SCRIPT" .gaia/statusline/gaia-statusline.sh
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".gaia/statusline/gaia-statusline.sh","reason":"denylist"}]}' ]
}

@test "denylist: .githooks/ (git runs these on commit and push)" {
  run "$SCRIPT" .githooks/pre-commit
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".githooks/pre-commit","reason":"denylist"}]}' ]
}

@test "denylist: .claude/settings.json (registers the hooks and statusline)" {
  run "$SCRIPT" .claude/settings.json
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".claude/settings.json","reason":"denylist"}]}' ]
}

@test "denylist: .claude/settings.local.json" {
  run "$SCRIPT" .claude/settings.local.json
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".claude/settings.local.json","reason":"denylist"}]}' ]
}

@test "denylist: .gaia/cli/gaia bundle overrides the .gaia/cli/ allowlist" {
  run "$SCRIPT" .gaia/cli/gaia
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".gaia/cli/gaia","reason":"denylist"}]}' ]
}

@test "denylist: .gaia/cli/gaia-maintainer bundle overrides the .gaia/cli/ allowlist" {
  run "$SCRIPT" .gaia/cli/gaia-maintainer
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".gaia/cli/gaia-maintainer","reason":"denylist"}]}' ]
}

@test "allowlist: .gaia/cli/src/ stays editable beside the denied bundles" {
  run "$SCRIPT" .gaia/cli/src/index.ts
  [ "$output" = '{"ok":true,"allowed":[".gaia/cli/src/index.ts"],"denied":[]}' ]
}

# --- install-time manifests -------------------------------------------------
# pnpm runs lifecycle scripts from every workspace member's manifest, and
# reads hooks and settings from the workspace and pnpmfile, so these deny by
# file name at any depth, under any allowlisted prefix.

@test "manifest: .gaia/cli/package.json is denied under the .gaia/cli/ allowlist" {
  run "$SCRIPT" .gaia/cli/package.json
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".gaia/cli/package.json","reason":"denylist"}]}' ]
}

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

@test "manifest: a package.json nested under an allowlisted prefix is denied" {
  run "$SCRIPT" .claude/skills/foo/package.json
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".claude/skills/foo/package.json","reason":"denylist"}]}' ]
}

@test "manifest: pnpm workspace, lockfile, npmrc and pnpmfile names are denied at any depth" {
  for name in pnpm-workspace.yaml pnpm-lock.yaml .npmrc .pnpmfile.cjs .pnpmfile.mjs; do
    run "$SCRIPT" "$name"
    [ "$output" = "{\"ok\":false,\"allowed\":[],\"denied\":[{\"path\":\"$name\",\"reason\":\"denylist\"}]}" ]
    run "$SCRIPT" ".gaia/cli/$name"
    [ "$output" = "{\"ok\":false,\"allowed\":[],\"denied\":[{\"path\":\".gaia/cli/$name\",\"reason\":\"denylist\"}]}" ]
  done
}

@test "manifest: a file name that only ends in package.json stays allowed" {
  run "$SCRIPT" .gaia/cli/src/not-package.json
  [ "$output" = '{"ok":true,"allowed":[".gaia/cli/src/not-package.json"],"denied":[]}' ]
}

# --- allowlist subtraction (UAT-007 edge case) -----------------------------

@test "subtraction: a file-level deny under .claude/skills/ overrides the parent allowlist" {
  run "$SCRIPT" .claude/skills/gaia/references/spec/spec-template.md
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".claude/skills/gaia/references/spec/spec-template.md","reason":"denylist"}]}' ]
}

# --- default-deny (UAT-014) ------------------------------------------------

@test "manifest: root package.json is denylisted" {
  run "$SCRIPT" package.json
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"package.json","reason":"denylist"}]}' ]
}

@test "default-deny: eslint.config.ts" {
  run "$SCRIPT" eslint.config.ts
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"eslint.config.ts","reason":"default-deny-unenumerated"}]}' ]
}

@test "default-deny: sibling of an allowlist prefix does not match" {
  # `.gaia/cliques/` is NOT `.gaia/cli/`; trailing-slash discipline prevents
  # bleed.
  run "$SCRIPT" .gaia/cliques/foo.sh
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".gaia/cliques/foo.sh","reason":"default-deny-unenumerated"}]}' ]
}

@test "default-deny: bare directory name without trailing path" {
  # Defensive: git diff names files, never bare directories. A bare
  # ".gaia/cli" does not match the ".gaia/cli/" prefix.
  run "$SCRIPT" .gaia/cli
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".gaia/cli","reason":"default-deny-unenumerated"}]}' ]
}

# --- multi-path partitioning -----------------------------------------------

@test "multi: all-allow → ok:true" {
  run "$SCRIPT" .gaia/cli/foo.sh .claude/skills/bar/SKILL.md .gaia/manifest.json
  [ "$output" = '{"ok":true,"allowed":[".gaia/cli/foo.sh",".claude/skills/bar/SKILL.md",".gaia/manifest.json"],"denied":[]}' ]
}

@test "multi: any-deny flips ok:false; allowed/denied partition the input" {
  run "$SCRIPT" .gaia/cli/foo.sh frontend/app/bar.ts eslint.config.ts
  [ "$output" = '{"ok":false,"allowed":[".gaia/cli/foo.sh"],"denied":[{"path":"frontend/app/bar.ts","reason":"denylist"},{"path":"eslint.config.ts","reason":"default-deny-unenumerated"}]}' ]
}

@test "multi: deny reasons are recorded per-path (mixed denylist + default-deny)" {
  run "$SCRIPT" wiki/foo.md eslint.config.ts
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"wiki/foo.md","reason":"denylist"},{"path":"eslint.config.ts","reason":"default-deny-unenumerated"}]}' ]
}

# --- zero-input contract ---------------------------------------------------

@test "no args: ok:true with empty arrays" {
  run "$SCRIPT"
  [ "$output" = '{"ok":true,"allowed":[],"denied":[]}' ]
}

# --- control-byte rejection (UAT-009) --------------------------------------
#
# JSON forbids unescaped U+0000..U+001F inside string literals. The script
# rejects any path containing a control byte with a structured error
# envelope rather than emitting malformed JSON. Filesystems forbid these
# in path names in practice; the rejection path defends against synthetic
# inputs (misbehaving callers, future test harnesses) and surfaces them
# as an explicit upstream signal.

@test "control-byte: tab (0x09) → reject with reason naming hex+position" {
  path=$(printf 'app/foo\tbar.ts')
  run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  case $output in
    *'"ok":false'*'"reason":"control-byte:0x09-at-position-7"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "control-byte: newline (0x0a) → reject with reason naming hex+position" {
  path=$(printf 'wiki/index\nmd')
  run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  case $output in
    *'"ok":false'*'"reason":"control-byte:0x0a-at-position-10"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "control-byte: carriage-return (0x0d) → reject" {
  path=$(printf 'a\rb')
  run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  case $output in
    *'"reason":"control-byte:0x0d-at-position-1"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "control-byte: U+0001 (SOH, 0x01) → reject" {
  path=$(printf 'foo\001bar')
  run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  case $output in
    *'"reason":"control-byte:0x01-at-position-3"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "control-byte: rejection envelope shape, ok:false, allowed:[], single denied entry" {
  path=$(printf 'x\ty')
  run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  # Whole envelope: allowed must be empty and denied must hold exactly the one entry.
  case $output in
    '{"ok":false,"allowed":[],"denied":[{"path":"x?y","reason":"control-byte:0x09-at-position-1"}]}') ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "control-byte: short-circuits before classifying remaining paths" {
  # First arg has a control byte; remaining args (allow + deny) must NOT
  # appear in the output, the rejection envelope replaces the normal
  # classification result.
  bad=$(printf 'bad\tpath')
  run "$SCRIPT" "$bad" .gaia/cli/foo.sh app/bar.ts
  [ "$status" -eq 0 ]
  case $output in
    *'.gaia/cli/foo.sh'*) printf 'allowlisted path leaked: %s\n' "$output" >&2; return 1 ;;
    *'app/bar.ts'*) printf 'denylisted path leaked: %s\n' "$output" >&2; return 1 ;;
    *'"reason":"control-byte:0x09-at-position-3"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "control-byte: rejection JSON parses with jq" {
  if ! command -v jq >/dev/null 2>&1; then
    skip "jq not available"
  fi
  path=$(printf 'a\tb')
  run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq . >/dev/null
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

@test "traversal: .. segment escapes allowlist prefix → reject" {
  run "$SCRIPT" '.claude/skills/../../.github/workflows/x.yml'
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".claude/skills/../../.github/workflows/x.yml","reason":"path-traversal:contains-..-segment"}]}' ]
}

@test "traversal: .. segment mid-path → reject" {
  run "$SCRIPT" '.gaia/cli/../manifest.json'
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".gaia/cli/../manifest.json","reason":"path-traversal:contains-..-segment"}]}' ]
}

@test "traversal: leading ../ → reject" {
  run "$SCRIPT" '../etc/passwd'
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"../etc/passwd","reason":"path-traversal:contains-..-segment"}]}' ]
}

@test "traversal: trailing /.. → reject" {
  run "$SCRIPT" '.gaia/cli/..'
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".gaia/cli/..","reason":"path-traversal:contains-..-segment"}]}' ]
}

@test "traversal: dotted filename without .. segment is unaffected" {
  # `.gaia/cli/foo.d.ts` has dots but no `..` path segment; classifies as allow.
  run "$SCRIPT" '.gaia/cli/foo.d.ts'
  [ "$output" = '{"ok":true,"allowed":[".gaia/cli/foo.d.ts"],"denied":[]}' ]
}

@test "traversal: .. substring that is not a path segment is unaffected" {
  # `foo..bar.ts` contains the `..` substring but not as a bounded segment;
  # the guard must not false-positive on it.
  run "$SCRIPT" '.gaia/cli/foo..bar.ts'
  [ "$output" = '{"ok":true,"allowed":[".gaia/cli/foo..bar.ts"],"denied":[]}' ]
}

@test "traversal: first offending path denies the whole invocation" {
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

@test "denylist: case variant of a denied file under an allowed prefix (.gaia/cli/GAIA)" {
  run "$SCRIPT" .gaia/cli/GAIA
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".gaia/cli/GAIA","reason":"denylist"}]}' ]
}

@test "denylist: case variant of a denied name under an allowed prefix (.gaia/cli/Package.json)" {
  run "$SCRIPT" .gaia/cli/Package.json
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".gaia/cli/Package.json","reason":"denylist"}]}' ]
}

# --- non-ASCII lookalikes ---------------------------------------------------

@test "non-ascii: a Kelvin-sign lookalike of a denied name is denied under LC_ALL=C" {
  path=$(printf '.gaia/cli/pac\xe2\x84\xaage.json')
  LC_ALL=C run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  case $output in
    *'"ok":false'*'"reason":"non-ascii-path"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "non-ascii: an otherwise allowed path with a non-ASCII byte is denied" {
  path=$(printf '.claude/skills/caf\xc3\xa9.md')
  run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  case $output in
    *'"ok":false'*'"reason":"non-ascii-path"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
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
