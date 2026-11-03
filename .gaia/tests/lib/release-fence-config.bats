#!/usr/bin/env bats
# Release configuration that has to follow the 2.0.0 apps/web/ move
# (SPEC-092 contracts C1, C8, C10).
#
#   M1-M3  the manifest classifier: no key at a retired root frontend path,
#          apps/web/ keys present, and the generated and adopter-owned files
#          absent from the manifest.
#   X1-X2  .gaia/release-exclude and .gaia/release-scrub.yml name no retired
#          root frontend path; X1 also drives a fixture that does and asserts
#          the check reports it.
#   S1     the scrub strips maintainer-only keys from both package.json files.
#   S2     the scrub strips the release-notes skill override from the shipped
#          root and frontend .claude/settings.json and keeps their siblings.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  MAINTAINER_CLI="$REPO_ROOT/.gaia/cli/gaia-maintainer"
  # Paths that moved under apps/web/ in 2.0.0. The root halves of the split
  # files (package.json, prettier.config.mjs, .prettierignore, .gitignore,
  # lockfile, workspace file) legitimately stay at the root and are not here.
  RETIRED_ROOT_PATTERN='^(app|test|public)(/|$)|^\.playwright(/|$)|^\.storybook(/|$)|^(tsconfig\.json|vite\.config\.ts|vitest\.config\.ts|playwright\.config\.ts|eslint\.config\.mjs|knip\.config\.ts|stylelint\.config\.mjs|react-router\.config\.ts|doctor\.config\.ts|Dockerfile|\.lintstagedrc\.json|\.dockerignore|\.env\.example)$'
}

# Retired root frontend paths named by a release-exclude body on stdin: the
# non-comment lines that match the retired pattern.
retired_lines_in_exclude() {
  grep -v '^[[:space:]]*#' | grep -E -- "$RETIRED_ROOT_PATTERN" || true
}

# Retired root frontend paths named as a quoted path in a release-scrub body on
# stdin (`- "app/..."` or `paths:` style entries).
retired_paths_in_scrub() {
  sed -n 's/^[[:space:]]*-[[:space:]]*"\([^"]*\)".*$/\1/p' | grep -E -- "$RETIRED_ROOT_PATTERN" || true
}

manifest_keys() {
  "$MAINTAINER_CLI" release manifest --stdout --allow-undecided | jq -r '.files | keys[]'
}

@test "M1: the manifest lists no key at a retired root frontend path and lists apps/web/app/root.tsx" {
  keys="$(manifest_keys)"
  [ -n "$keys" ]
  retired="$(printf '%s\n' "$keys" | grep -E -- "$RETIRED_ROOT_PATTERN" || true)"
  [ -z "$retired" ]
  printf '%s\n' "$keys" | grep -qxF 'apps/web/app/root.tsx'
}

@test "M2: the generated settings and the package registry are not in the manifest; the descriptor and overlay are" {
  keys="$(manifest_keys)"
  printf '%s\n' "$keys" | grep -qxF 'apps/web/.claude/settings.json' && return 1
  printf '%s\n' "$keys" | grep -qxF '.gaia/packages.json' && return 1
  printf '%s\n' "$keys" | grep -qxF 'apps/web/gaia.package.json'
  printf '%s\n' "$keys" | grep -qxF 'apps/web/.claude/settings.overlay.json'
  printf '%s\n' "$keys" | grep -qxF 'apps/web/package.json'
}

@test "M3: the retired-path pattern flags a root app path (the check can fail)" {
  printf 'app/root.tsx\n' | grep -qE -- "$RETIRED_ROOT_PATTERN"
  printf 'Dockerfile\n' | grep -qE -- "$RETIRED_ROOT_PATTERN"
  printf 'apps/web/app/root.tsx\n' | grep -qE -- "$RETIRED_ROOT_PATTERN" && return 1
  printf 'prettier.config.mjs\n' | grep -qE -- "$RETIRED_ROOT_PATTERN" && return 1
  true
}

@test "X1: release-exclude names no retired root frontend path, and a fixture that does is reported" {
  [ -z "$(retired_lines_in_exclude < "$REPO_ROOT/.gaia/release-exclude")" ]
  # The canary line is the one that was keyed at the root before the move.
  grep -qxF 'apps/web/.playwright/e2e/react-perf-smoke.spec.ts' "$REPO_ROOT/.gaia/release-exclude"
  fixture="$BATS_TEST_TMPDIR/exclude-old"
  printf '# comment\n.playwright/e2e/react-perf-smoke.spec.ts\n' > "$fixture"
  [ "$(retired_lines_in_exclude < "$fixture")" = '.playwright/e2e/react-perf-smoke.spec.ts' ]
}

@test "X2: release-scrub names no retired root frontend path, and a fixture that does is reported" {
  [ -z "$(retired_paths_in_scrub < "$REPO_ROOT/.gaia/release-scrub.yml")" ]
  fixture="$BATS_TEST_TMPDIR/scrub-old"
  printf '    paths:\n      - "app/routes/x.tsx"\n' > "$fixture"
  [ "$(retired_paths_in_scrub < "$fixture")" = 'app/routes/x.tsx' ]
}

@test "S1: the maintainer-only package.json keys are stripped from both shipped package.json files" {
  staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging/apps/web" "$staging/.gaia"
  printf '{"name":"x","bin":{"gaia":"./g"},"scripts":{"test:forensics":"a","test:sandbox":"b","dev":"c"}}\n' > "$staging/package.json"
  printf '{"name":"frontend","bin":{"x":"./x"},"scripts":{"test:forensics":"a","dev":"c"}}\n' > "$staging/apps/web/package.json"
  # Only the package.json json-strip transform: keep the first transform block
  # that names package.json by writing a minimal config of our own with the
  # keys the real config lists.
  config="$BATS_TEST_TMPDIR/scrub.yml"
  keys="$(awk '/^  - type: json-strip$/{f=1} f&&/^    keys:/{k=1;next} k&&/^      - /{print;next} k&&!/^      - /{exit}' "$REPO_ROOT/.gaia/release-scrub.yml")"
  paths="$(awk '/^  - type: json-strip$/{f=1} f&&/^    paths:/{p=1;next} p&&/^      - /{print;next} p&&!/^      - /{exit}' "$REPO_ROOT/.gaia/release-scrub.yml")"
  printf '%s\n' "$paths" | grep -qF '"package.json"'
  printf '%s\n' "$paths" | grep -qF '"apps/web/package.json"'
  printf '%s\n' "$keys" | grep -qF '"bin"'
  printf 'transforms:\n  - type: json-strip\n    paths:\n%s\n    keys:\n%s\n' "$paths" "$keys" > "$config"
  run "$MAINTAINER_CLI" release scrub "$staging" --config "$config"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.bin // "absent"' "$staging/package.json")" = absent ]
  [ "$(jq -r '.scripts["test:forensics"] // "absent"' "$staging/package.json")" = absent ]
  [ "$(jq -r '.bin // "absent"' "$staging/apps/web/package.json")" = absent ]
  [ "$(jq -r '.scripts["test:forensics"] // "absent"' "$staging/apps/web/package.json")" = absent ]
  [ "$(jq -r '.scripts.dev' "$staging/apps/web/package.json")" = c ]
}

@test "S2: the release-notes skill override is stripped from both shipped .claude/settings.json files and their siblings stay" {
  staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging/.claude" "$staging/apps/web/.claude"
  printf '{"skillOverrides":{"gaia-debt":"name-only","release-notes":"name-only"},"model":"x"}\n' > "$staging/.claude/settings.json"
  cp "$staging/.claude/settings.json" "$staging/apps/web/.claude/settings.json"
  # The json-strip block whose paths name .claude/settings.json, taken from the
  # real config so the test follows its keys.
  block="$(awk '
    /^  - type: /{ if (keep) exit; inblock = ($0 == "  - type: json-strip"); buf = ""; next }
    inblock && /^    paths:/{ buf = buf $0 "\n"; next }
    inblock && /^    keys:/{ buf = buf $0 "\n"; next }
    inblock && /^      - /{ buf = buf $0 "\n"; if ($0 ~ /"\.claude\/settings\.json"/) keep = 1; next }
    END { if (keep) printf "%s", buf }
  ' "$REPO_ROOT/.gaia/release-scrub.yml")"
  printf '%s\n' "$block" | grep -qF '"skillOverrides.release-notes"'
  printf '%s\n' "$block" | grep -qF '"apps/web/.claude/settings.json"'
  config="$BATS_TEST_TMPDIR/scrub.yml"
  printf 'transforms:\n  - type: json-strip\n%s\n' "$block" > "$config"
  run "$MAINTAINER_CLI" release scrub "$staging" --config "$config"
  [ "$status" -eq 0 ]
  for settings in "$staging/.claude/settings.json" "$staging/apps/web/.claude/settings.json"; do
    [ "$(jq -r '.skillOverrides["release-notes"] // "absent"' "$settings")" = absent ]
    [ "$(jq -r '.skillOverrides["gaia-debt"]' "$settings")" = name-only ]
    [ "$(jq -r '.model' "$settings")" = x ]
  done
}
