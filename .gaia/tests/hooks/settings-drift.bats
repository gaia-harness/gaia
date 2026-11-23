#!/usr/bin/env bats

# Tests for the generated per-package Claude settings (SPEC-092 contract C8):
# `gaia packages sync-settings`, `.gaia/scripts/check-settings-drift.sh`, the
# drift and MIG-013 arms of `.githooks/pre-commit`, and the root settings the
# frontend session needs.
#
# Three kinds of case. Reads of the live tree assert the committed shape with jq
# and never run git. Scratch-tree cases copy the code under test into a temp git
# repo, so a mutation never touches this checkout. Failing-state cases drive each
# guard into the state it exists to refuse and assert it refuses.
#
# Git runs the hook directly, so the hook cases do too, with `pnpm` stubbed onto
# PATH. Assertion style: .claude/rules/bats-assertions.md.

# bats file_tags=installed-dependencies

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  ROOT_SETTINGS="$REPO_ROOT/.claude/settings.json"
  GENERATED="$REPO_ROOT/apps/web/.claude/settings.json"
  # shellcheck source=helpers/package-fixture.sh
  . "$BATS_TEST_DIRNAME/helpers/package-fixture.sh"
  TREE=""
  TEMPLATE=""
}

teardown() {
  if [ -n "${TREE:-}" ]; then
    rm -rf "$TREE"
  fi
  if [ -n "${TEMPLATE:-}" ]; then
    rm -rf "$TEMPLATE"
  fi
  return 0
}

# build_tree: a scratch git repo carrying the code under test (hook, helper,
# drift script, registry reader, CLI bundle) and the live settings files, with
# the live tree's registry state written as a literal.
build_tree() {
  TREE=$(cd "$(mktemp -d -t settings-drift-XXXXXX)" && pwd -P)
  git -C "$TREE" init --quiet --initial-branch=main
  git -C "$TREE" config user.email "test@example.com"
  git -C "$TREE" config user.name "Test"
  git -C "$TREE" config commit.gpgsign false
  mkdir -p "$TREE/.claude/hooks/lib" "$TREE/.gaia/scripts" "$TREE/.gaia/cli" \
    "$TREE/apps/web/.claude" "$TREE/stub-bin"
  cp "$ROOT_SETTINGS" "$TREE/.claude/settings.json"
  cp "$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh" "$TREE/.claude/hooks/lib/"
  cp "$REPO_ROOT/.gaia/scripts/check-settings-drift.sh" "$TREE/.gaia/scripts/"
  cp "$REPO_ROOT/.gaia/scripts/precommit-packages.sh" "$TREE/.gaia/scripts/"
  # The CLI runs from source, so a change not yet rebuilt into the committed
  # bundle is what the suite exercises.
  # pnpm is named by absolute path because the hook cases put a stub pnpm first
  # on PATH.
  printf '#!/bin/sh\nexec "%s" -C "%s/.gaia/cli" exec tsx src/index.ts "$@"\n' "$(command -v pnpm)" "$REPO_ROOT" >"$TREE/.gaia/cli/gaia"
  cp "$REPO_ROOT/apps/web/.claude/settings.json" "$TREE/apps/web/.claude/"
  cp "$REPO_ROOT/apps/web/.claude/settings.overlay.json" "$TREE/apps/web/.claude/"
  write_packages_moved "$TREE"
  # The shared fixture descriptor carries no stack, and full generated settings
  # apply to a web-stack member.
  jq '.stack = "web"' "$TREE/apps/web/gaia.package.json" >"$TREE/apps/web/gaia.package.json.next"
  mv "$TREE/apps/web/gaia.package.json.next" "$TREE/apps/web/gaia.package.json"
  printf '#!/bin/sh\nexit 0\n' >"$TREE/stub-bin/pnpm"
  chmod +x "$TREE/stub-bin/pnpm" "$TREE/.gaia/cli/gaia"
  git -C "$TREE" add -A
  git -C "$TREE" commit --quiet -m "baseline"
}

# build_template: build_tree once, kept as TEMPLATE for next_case to clone, so a
# case table pays for one git init and commit instead of one per case.
build_template() {
  build_tree
  TEMPLATE="$TREE"
  TREE=""
}

# next_case <row>: names the row (printed with a failure) and gives it a fresh
# copy of TEMPLATE as TREE, discarding the previous case's copy.
next_case() {
  echo "row: $1"
  if [ -n "${TREE:-}" ]; then
    rm -rf "$TREE"
  fi
  TREE=$(cd "$(mktemp -d -t settings-drift-XXXXXX)" && pwd -P)
  cp -R "$TEMPLATE/." "$TREE/"
}

run_drift() {
  run bash "$TREE/.gaia/scripts/check-settings-drift.sh" "$TREE"
}

run_hook() {
  run env PATH="$TREE/stub-bin:$PATH" \
    sh -c 'cd "$1" && "$2"' _ "$TREE" "$REPO_ROOT/.githooks/pre-commit"
}

regenerate() {
  "$TREE/.gaia/cli/gaia" packages sync-settings --repo-root "$TREE" >/dev/null
}

# --- the committed shape ---

@test "root settings carry the expected allow and deny rules" {
  # One row per rule: <permissions list>|<present or absent>|<rule>.
  local row list want rule
  for row in \
    'allow|present|Edit(apps/web/app/**)' \
    'allow|absent|Edit(app/**)' \
    'allow|absent|Edit(test/**)' \
    'allow|absent|Edit(public/**)' \
    'allow|absent|Edit(.playwright/**)' \
    'allow|absent|Edit(.storybook/**)' \
    'allow|present|Edit(apps/web/.claude/agents/**)' \
    'allow|present|Edit(apps/web/.claude/instructions/**)' \
    'allow|present|Edit(apps/web/.claude/rules/**)' \
    'allow|present|Edit(apps/web/.claude/skills/**)' \
    'deny|present|Edit(**/.env)' \
    'deny|present|Edit(.env)' \
    'deny|present|Edit(apps/web/.claude/settings.json)' \
    'deny|absent|Edit(**/.env.*)' \
    'allow|present|Bash(pnpm -C apps/web typecheck:*)' \
    'allow|present|Bash(pnpm -C apps/web lint)' \
    'allow|present|Bash(pnpm -C apps/web exec playwright test:*)' \
    'allow|present|Bash(pnpm -C .gaia/cli bundle)' \
    'allow|absent|Bash(pnpm -C apps/web:*)' \
    'allow|absent|Bash(pnpm -C apps/web exec:*)' \
    'allow|absent|Bash(pnpm -C .gaia/cli:*)'; do
    IFS='|' read -r list want rule <<<"$row"
    echo "row: $row"
    # A .env.* deny also blocks the tracked, editable .env.example; block-secrets-write.sh covers it.
    if [ "$want" = present ]; then
      jq -e --arg l "$list" --arg r "$rule" '.permissions[$l] | index($r) != null' "$ROOT_SETTINGS"
    else
      jq -e --arg l "$list" --arg r "$rule" '.permissions[$l] | index($r) == null' "$ROOT_SETTINGS"
    fi
  done
}

@test "the generated file re-anchors the root denies to the web launch dir" {
  local pair root_form anchored
  for pair in 'Edit(.env)|Edit(../../.env)' \
    'Edit(apps/web/.claude/settings.json)|Edit(../../apps/web/.claude/settings.json)' \
    'Edit(.gaia/local/audit/*.ok)|Edit(../../.gaia/local/audit/*.ok)' \
    'Edit(pnpm-lock.yaml)|Edit(../../pnpm-lock.yaml)'; do
    root_form="${pair%%|*}"
    anchored="${pair#*|}"
    jq -e --arg r "$root_form" '.permissions.deny | index($r) != null' "$ROOT_SETTINGS"
    jq -e --arg r "$anchored" '.permissions.deny | index($r) != null' "$GENERATED"
    jq -e --arg r "$root_form" '.permissions.deny | index($r) == null' "$GENERATED"
  done
  jq -e '.permissions.deny | index("Edit(**/.env)") != null' "$GENERATED"
  jq -e '.sandbox.filesystem.denyRead | index("../../.env") != null' "$GENERATED"
  jq -e '.sandbox.filesystem.denyRead | index("**/.env") != null' "$GENERATED"
  jq -e '.permissions.additionalDirectories == ["../.."]' "$GENERATED"
}

@test "the generated file copies hooks and statusLine byte for byte" {
  [ "$(jq -cS '.hooks' "$ROOT_SETTINGS")" = "$(jq -cS '.hooks' "$GENERATED")" ]
  [ "$(jq -c '.statusLine' "$ROOT_SETTINGS")" = "$(jq -c '.statusLine' "$GENERATED")" ]
}

# bats test_tags=whole-tree
@test "the committed tree passes the drift check" {
  run bash "$REPO_ROOT/.gaia/scripts/check-settings-drift.sh" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF -- "check-settings-drift: clean" <<<"$output"
}

# --- the drift check can fail ---

# bats test_tags=protected
@test "a changed root hook command without regenerating is drift naming the generated file" {
  build_tree
  jq '.hooks.PreToolUse[0].hooks[0].command = "other.sh"' "$TREE/.claude/settings.json" >"$TREE/changed.json"
  mv "$TREE/changed.json" "$TREE/.claude/settings.json"
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "apps/web/.claude/settings.json" <<<"$output"
  git -C "$TREE" add .claude/settings.json
  run_hook
  [ "$status" -ne 0 ]
  grep -qF -- "packages sync-settings" <<<"$output"
  regenerate
  git -C "$TREE" add apps/web/.claude/settings.json
  run_drift
  [ "$status" -eq 0 ]
  run_hook
  [ "$status" -eq 0 ]
}

@test "mutating only the overlay is drift" {
  build_tree
  printf '{"permissions":{"allow":["Edit(extra/**)"]}}\n' >"$TREE/apps/web/.claude/settings.overlay.json"
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "apps/web/.claude/settings.json" <<<"$output"
  git -C "$TREE" add apps/web/.claude/settings.overlay.json
  run_hook
  [ "$status" -ne 0 ]
  regenerate
  run_drift
  [ "$status" -eq 0 ]
  jq -e '.permissions.allow | index("Edit(extra/**)") != null' "$TREE/apps/web/.claude/settings.json"
}

# bats test_tags=protected
@test "the presence assertion fails on a dropped deny even when the generator reports clean" {
  build_tree
  # A generator that always agrees with itself: only the independent jq
  # assertion is left to notice the missing entry.
  printf '#!/bin/sh\nexit 0\n' >"$TREE/.gaia/cli/gaia"
  jq '.permissions.deny |= map(select(. != "Edit(../../.env)"))' "$TREE/apps/web/.claude/settings.json" >"$TREE/changed.json"
  mv "$TREE/changed.json" "$TREE/apps/web/.claude/settings.json"
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "apps/web/.claude/settings.json is missing" <<<"$output"
  grep -qF -- "Edit(../../.env)" <<<"$output"
}

@test "the presence assertion fails on each dropped or rewritten root entry" {
  build_template
  local command_json

  next_case "dropped hook command and dropped additionalDirectories"
  printf '#!/bin/sh\nexit 0\n' >"$TREE/.gaia/cli/gaia"
  jq 'del(.hooks.PreToolUse[0].hooks[0]) | del(.permissions.additionalDirectories)' "$TREE/apps/web/.claude/settings.json" >"$TREE/changed.json"
  mv "$TREE/changed.json" "$TREE/apps/web/.claude/settings.json"
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "PreToolUse hook command" <<<"$output"
  grep -qF -- 'additionalDirectories entry "../.."' <<<"$output"

  next_case "generated handler dropped the root's if"
  printf '#!/bin/sh\nexit 0\n' >"$TREE/.gaia/cli/gaia"
  set_handler_if "$TREE/.claude/settings.json" 0 'Bash(git *)'
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "apps/web/.claude/settings.json is missing" <<<"$output"
  command_json=$(jq -c '.hooks.PreToolUse[0].hooks[0].command' "$TREE/.claude/settings.json")
  grep -qF -- "$command_json" <<<"$output"
  grep -qF -- '"Bash(git *)"' <<<"$output"

  next_case "generated handler's if was rewritten"
  printf '#!/bin/sh\nexit 0\n' >"$TREE/.gaia/cli/gaia"
  set_handler_if "$TREE/.claude/settings.json" 0 'Bash(git *)'
  set_handler_if "$TREE/apps/web/.claude/settings.json" 0 'Bash(gh *)'
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "apps/web/.claude/settings.json is missing" <<<"$output"
  command_json=$(jq -c '.hooks.PreToolUse[0].hooks[0].command' "$TREE/.claude/settings.json")
  grep -qF -- "$command_json" <<<"$output"
  grep -qF -- '"Bash(git *)"' <<<"$output"

  next_case "one of two same-command handlers missing from the generated file"
  printf '#!/bin/sh\nexit 0\n' >"$TREE/.gaia/cli/gaia"
  # The generated file carries the handler with the first rule only; the root
  # also carries a copy of it with a second rule.
  set_handler_if "$TREE/.claude/settings.json" 0 'Bash(git *)'
  set_handler_if "$TREE/apps/web/.claude/settings.json" 0 'Bash(git *)'
  jq '.hooks.PreToolUse[0].hooks += [.hooks.PreToolUse[0].hooks[0] | .["if"] = "Bash(gh pr merge *)"]' \
    "$TREE/.claude/settings.json" >"$TREE/changed.json"
  mv "$TREE/changed.json" "$TREE/.claude/settings.json"
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "apps/web/.claude/settings.json is missing" <<<"$output"
  command_json=$(jq -c '.hooks.PreToolUse[0].hooks[0].command' "$TREE/.claude/settings.json")
  grep -qF -- "$command_json" <<<"$output"
  grep -qF -- '"Bash(gh pr merge *)"' <<<"$output"
  grep -qF -- '"Bash(git *)"' <<<"$output" && return 1
  true
}

# set_handler_if <settings file> <hook index> <if rule>: set one PreToolUse handler's if.
set_handler_if() {
  jq --argjson i "$2" --arg r "$3" '.hooks.PreToolUse[0].hooks[$i]["if"] = $r' "$1" >"$TREE/changed.json"
  mv "$TREE/changed.json" "$1"
}

@test "the presence assertion passes when root and generated agree on command and if" {
  build_tree
  printf '#!/bin/sh\nexit 0\n' >"$TREE/.gaia/cli/gaia"
  set_handler_if "$TREE/.claude/settings.json" 0 'Bash(git *)'
  set_handler_if "$TREE/apps/web/.claude/settings.json" 0 'Bash(git *)'
  run_drift
  [ "$status" -eq 0 ]
  grep -qF -- "check-settings-drift: clean" <<<"$output"
}

# deny_guards_with_if <settings file>: prints "<event> <script>" for every deny guard
# handler that carries an if. The filter is best-effort and the guards' verb arming
# is fail-closed, so none may carry one.
deny_guards_with_if() {
  jq -r '.hooks | to_entries[] | .key as $event | .value[] | .hooks[]
    | select(.["if"]) | (.command | capture("hooks/(?<name>[^\"]+)").name) as $name
    | select($name | test("^(block-.*|pr-merge-audit-check|worthiness-presence-check)\\.sh$"))
    | "\($event) \($name)"' "$1"
}

@test "no deny guard handler in the root or generated settings carries an if" {
  [ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | test("hooks/block-"))] | length' "$ROOT_SETTINGS")" -gt 0 ]
  [ -z "$(deny_guards_with_if "$ROOT_SETTINGS")" ]
  [ -z "$(deny_guards_with_if "$GENERATED")" ]
}

@test "the deny-guard if check reports a deny guard handler given an if" {
  build_tree
  jq '(.hooks.PreToolUse[].hooks[] | select(.command | test("hooks/block-no-verify.sh"))) |= . + {"if": "Bash(git *)"}' \
    "$TREE/.claude/settings.json" >"$TREE/changed.json"
  mv "$TREE/changed.json" "$TREE/.claude/settings.json"
  run deny_guards_with_if "$TREE/.claude/settings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "PreToolUse block-no-verify.sh" ]
}

@test "the drift check refuses to report clean when it cannot read its inputs" {
  build_template

  next_case "missing generated file"
  rm "$TREE/apps/web/.claude/settings.json"
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "apps/web/.claude/settings.json" <<<"$output"

  next_case "missing CLI bundle"
  rm "$TREE/.gaia/cli/gaia"
  run_drift
  [ "$status" -eq 2 ]
  grep -qF -- "Next step" <<<"$output"

  next_case "malformed registry"
  printf '[{"name":"frontend"}]\n' >"$TREE/.gaia/packages.json"
  run_drift
  [ "$status" -eq 2 ]
  grep -qF -- "gaia-packages" <<<"$output"
}

# --- generation guards (CLI, driven through the real bundle) ---

assert_generation_refused() {
  local before after
  before=$(cksum <"$TREE/apps/web/.claude/settings.json")
  run "$TREE/.gaia/cli/gaia" packages sync-settings --repo-root "$TREE"
  [ "$status" -eq 2 ]
  grep -qF -- "settings_generation_failed" <<<"$output"
  after=$(cksum <"$TREE/apps/web/.claude/settings.json")
  [ "$before" = "$after" ]
}

@test "generation refuses each hostile overlay or registry input and writes nothing" {
  build_template
  # One row per overlay: <overlay JSON>|<expected message>.
  local row overlay message
  for row in \
    '{"hooks":{}}|overlay key \"hooks\"' \
    '{"sandbox":{}}|overlay key \"sandbox\"' \
    '{"permissions":{"allow":["Edit(pnpm-lock.yaml)"]}}|re-open what the root denies' \
    '{"permissions":{"allow":["Edit(a$(x))"]}}|characters outside'; do
    overlay="${row%%|*}"
    message="${row#*|}"
    next_case "overlay $overlay"
    printf '%s\n' "$overlay" >"$TREE/apps/web/.claude/settings.overlay.json"
    assert_generation_refused
    grep -qF -- "$message" <<<"$output"
  done
  local hostile
  for hostile in 'front end' 'apps/web/../x'; do
    next_case "registry package path $hostile"
    printf '[{"name":"frontend","path":"%s"}]\n' "$hostile" >"$TREE/.gaia/packages.json"
    run "$TREE/.gaia/cli/gaia" packages sync-settings --repo-root "$TREE"
    [ "$status" -eq 2 ]
    grep -qF -- "malformed" <<<"$output"
  done
}

# --- MIG-013: no new files under a retired root path ---

@test "the retired-root-path block refuses each retired directory and allows apps/web files, a registered root package and a C13 rename" {
  build_template
  local directory
  next_case "retired root directories"
  for directory in app test public .playwright .storybook; do
    echo "row: retired $directory"
    mkdir -p "$TREE/$directory"
    printf 'x\n' >"$TREE/$directory/new.ts"
    git -C "$TREE" add "$directory/new.ts"
    run_hook
    [ "$status" -ne 0 ]
    grep -qF -- "$directory/new.ts -> apps/web/$directory/new.ts" <<<"$output"
    git -C "$TREE" rm --cached --quiet "$directory/new.ts"
  done

  next_case "a new apps/web/app file is allowed"
  mkdir -p "$TREE/apps/web/app"
  printf 'x\n' >"$TREE/apps/web/app/x.tsx"
  git -C "$TREE" add apps/web/app/x.tsx
  run_hook
  [ "$status" -eq 0 ]
  grep -qF -- "running lint-staged" <<<"$output"

  next_case "the block stands down while a package is registered at the root"
  write_packages_today "$TREE"
  rm -rf "$TREE/apps/web/gaia.package.json"
  mkdir -p "$TREE/app"
  printf 'x\n' >"$TREE/app/x.tsx"
  git -C "$TREE" add app/x.tsx
  run_hook
  [ "$status" -eq 0 ]

  next_case "a C13-exempt rename staged alone is allowed"
  mkdir -p "$TREE/apps/web/app"
  mkdir -p "$TREE/app"
  printf 'content that is long enough to keep rename detection exact\n' >"$TREE/app/y.ts"
  git -C "$TREE" add app/y.ts
  git -C "$TREE" commit --quiet -m "legacy file"
  git -C "$TREE" mv app/y.ts apps/web/app/y.ts
  run_hook
  [ "$status" -eq 0 ]
  grep -qF -- "migration renames staged" <<<"$output"
}

