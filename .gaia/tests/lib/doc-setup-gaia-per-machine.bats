#!/usr/bin/env bats
# Phase 2 per-machine setup, driven by the per-machine reference under
# `.claude/skills/gaia/references/setup/`:
#
#   - claude-obsidian installs at project scope: every install line on the
#     setup surface (`.claude/commands/setup-gaia.md` followed by every setup
#     reference) carries `--scope project`, and `.claude/settings.json`
#     enables the plugin and declares its marketplace.
#   - The claude-obsidian probe, extracted and run against a stubbed `claude`,
#     passes only a project-scope record for this repository root.
#   - The React Doctor probe names the `frontend/` skill location, and neither
#     the setup surface nor `.claude/commands/gaia-init.md` carries the
#     root-level probe.
#
# Every test that proves the real files pass has a twin that runs the same
# check over a scratch copy with the guarded content removed or the old
# content put back and asserts it fails.
#
# Assertion style: .claude/rules/bats-assertions.md.

# Each reference basename is named literally in this list: the change selector
# picks a suite only when it contains a changed file's basename, and this suite
# reads every reference through surface_files.
EXPECTED_SETUP_REFERENCES="per-machine.md sandbox.md github-repo.md isolation-question.md squash-only.md statusline-left.md setup-decisions.md standalone-features.md land-decisions.md sandbox-recommendation.md"

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/.claude/commands/setup-gaia.md"
  INIT_PAGE="${REPO_ROOT}/.claude/commands/gaia-init.md"
  REFERENCES_DIRECTORY="${REPO_ROOT}/.claude/skills/gaia/references/setup"
  PER_MACHINE_REFERENCE="${REFERENCES_DIRECTORY}/per-machine.md"
  SETTINGS_FILE="${REPO_ROOT}/.claude/settings.json"
  [ -f "$PAGE" ] || {
    echo "the audited page is absent: ${PAGE}" >&2
    return 1
  }
  [ -f "$INIT_PAGE" ] || {
    echo "the init page is absent: ${INIT_PAGE}" >&2
    return 1
  }
  [ -d "$REFERENCES_DIRECTORY" ] || {
    echo "the setup references directory is absent: ${REFERENCES_DIRECTORY}" >&2
    return 1
  }
}

# scratch_copy <source> <name>: copy a file into the test's temp dir and print
# the copy's path, so a mutation never touches the shared tree.
scratch_copy() {
  local copy="${BATS_TEST_TMPDIR}/$2"
  cp "$1" "$copy"
  printf '%s\n' "$copy"
}

# scratch_references <name>: copy the setup references directory into the
# test's temp dir and print the copy's path.
scratch_references() {
  local copy="${BATS_TEST_TMPDIR}/$1"
  mkdir -p "$copy"
  cp "${REFERENCES_DIRECTORY}"/*.md "$copy"/
  printf '%s\n' "$copy"
}

# surface_files <entry> <directory>: the setup surface, one path per line: the
# entry command, then each expected reference from <directory> in list order.
# Fails loudly on an absent file so the surface can never be a short read.
surface_files() {
  local entry="$1" directory="$2" name
  [ -f "$entry" ] || {
    echo "surface entry is absent: ${entry}" >&2
    return 1
  }
  printf '%s\n' "$entry"
  for name in $EXPECTED_SETUP_REFERENCES; do
    [ -f "${directory}/${name}" ] || {
      echo "surface reference is absent: ${directory}/${name}" >&2
      return 1
    }
    printf '%s\n' "${directory}/${name}"
  done
}

# build_surface <entry> <directory> <name>: concatenate the setup surface into
# one file and print its path.
build_surface() {
  local output="${BATS_TEST_TMPDIR}/$3" file files
  files="$(surface_files "$1" "$2")" || return 1
  : >"$output"
  while IFS= read -r file; do
    cat "$file" >>"$output"
  done <<<"$files"
  printf '%s\n' "$output"
}

# real_surface: the surface of the real command and references.
real_surface() {
  build_surface "$PAGE" "$REFERENCES_DIRECTORY" surface-real.md
}

# ---------------------------------------------------------------------------
# claude-obsidian installs at project scope
# ---------------------------------------------------------------------------

# check_project_scope_plugin <surface-file> <settings-file>: every
# claude-obsidian install line carries --scope project, the committed settings
# enable the plugin, and they declare its marketplace.
check_project_scope_plugin() {
  local surface="$1" settings="$2" lines bad
  lines="$(grep -F 'claude plugin install claude-obsidian@' "$surface" || true)"
  [ -n "$lines" ] || {
    echo "the surface has no claude-obsidian install line" >&2
    return 1
  }
  bad="$(grep -vF -- '--scope project' <<<"$lines" || true)"
  [ -z "$bad" ] || {
    echo "a claude-obsidian install line lacks --scope project: ${bad}" >&2
    return 1
  }
  jq -e '.enabledPlugins["claude-obsidian@agricidaniel-claude-obsidian"] == true' "$settings" >/dev/null || {
    echo "the settings do not enable claude-obsidian" >&2
    return 1
  }
  jq -e '.extraKnownMarketplaces["agricidaniel-claude-obsidian"].source == {"source":"github","repo":"AgriciDaniel/claude-obsidian"}' "$settings" >/dev/null || {
    echo "the settings do not declare the claude-obsidian marketplace" >&2
    return 1
  }
}

@test "claude-obsidian installs at project scope and the settings enable and declare it" {
  check_project_scope_plugin "$(real_surface)" "$SETTINGS_FILE"
}

@test "the project-scope check fails when --scope project is stripped from an install line" {
  local directory surface
  directory="$(scratch_references scope-stripped)"
  sed 's/ --scope project//' "${REFERENCES_DIRECTORY}/per-machine.md" >"${directory}/per-machine.md"
  cmp -s "${REFERENCES_DIRECTORY}/per-machine.md" "${directory}/per-machine.md" && return 1
  surface="$(build_surface "$PAGE" "$directory" surface-scope-stripped.md)"
  run check_project_scope_plugin "$surface" "$SETTINGS_FILE"
  [ "$status" -ne 0 ]
  grep -qF 'lacks --scope project' <<<"$output"
}

@test "the project-scope check fails when the settings do not enable the plugin" {
  local settings="${BATS_TEST_TMPDIR}/settings-no-plugin.json"
  jq 'del(.enabledPlugins["claude-obsidian@agricidaniel-claude-obsidian"])' "$SETTINGS_FILE" >"$settings"
  cmp -s "$SETTINGS_FILE" "$settings" && return 1
  run check_project_scope_plugin "$(real_surface)" "$settings"
  [ "$status" -ne 0 ]
  grep -qF 'do not enable' <<<"$output"
}

@test "the project-scope check fails when the settings do not declare the marketplace" {
  local settings="${BATS_TEST_TMPDIR}/settings-no-marketplace.json"
  jq 'del(.extraKnownMarketplaces)' "$SETTINGS_FILE" >"$settings"
  cmp -s "$SETTINGS_FILE" "$settings" && return 1
  run check_project_scope_plugin "$(real_surface)" "$settings"
  [ "$status" -ne 0 ]
  grep -qF 'do not declare' <<<"$output"
}

# ---------------------------------------------------------------------------
# The claude-obsidian probe, executed against a stubbed claude
# ---------------------------------------------------------------------------

# bash_fence_containing <anchor> <file>: print the body of the one bash fence
# containing the anchor; fails unless there is exactly one.
bash_fence_containing() {
  awk -v anchor="$1" '
    /^```bash[[:space:]]*$/ { inside = 1; body = ""; next }
    /^```[[:space:]]*$/ && inside {
      inside = 0
      if (index(body, anchor)) { printf "%s", body; found++ }
      next
    }
    inside { body = body $0 "\n" }
    END { if (found != 1) exit 1 }
  ' "$2"
}

# run_probe_fixture <fence> <repository> <stub-directory> <fixture-json>: run
# the probe inside the repository with a `claude` stub that answers
# `plugin list --json` with the fixture; the stub's status is the probe's.
run_probe_fixture() {
  (
    cd "$2" || exit 1
    PROBE_FIXTURE="$4" PATH="$3:${PATH}" bash "$1"
  )
}

# assert_probe_behavior <fence>: a user-scope record, a project-scope record
# for another path, and another plugin's record for this root all fail; a
# project-scope record whose projectPath is this root passes.
assert_probe_behavior() {
  local fence="$1" repository="${BATS_TEST_TMPDIR}/probe-repository" stub_directory="${BATS_TEST_TMPDIR}/probe-bin"
  local root plugin_id="claude-obsidian@agricidaniel-claude-obsidian" fixture name
  rm -rf "$repository" "$stub_directory"
  mkdir -p "$repository" "$stub_directory"
  git init -q "$repository" || return 1
  root="$(git -C "$repository" rev-parse --show-toplevel)" || return 1
  cat >"${stub_directory}/claude" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "plugin list --json" ] || exit 1
printf '%s\n' "$PROBE_FIXTURE"
STUB
  chmod +x "${stub_directory}/claude"
  for name in user-only user-with-path other-path other-plugin; do
    case "$name" in
      user-only) fixture="$(jq -nc --arg id "$plugin_id" '[{id: $id, scope: "user", enabled: true, projectPath: null}]')" ;;
      user-with-path) fixture="$(jq -nc --arg id "$plugin_id" --arg root "$root" '[{id: $id, scope: "user", enabled: true, projectPath: $root}]')" ;;
      other-path) fixture="$(jq -nc --arg id "$plugin_id" '[{id: $id, scope: "project", enabled: true, projectPath: "/somewhere/else"}]')" ;;
      other-plugin) fixture="$(jq -nc --arg root "$root" '[{id: "typescript-lsp@claude-plugins-official", scope: "project", enabled: true, projectPath: $root}]')" ;;
    esac
    if run_probe_fixture "$fence" "$repository" "$stub_directory" "$fixture"; then
      echo "the probe passed the ${name} fixture" >&2
      return 1
    fi
  done
  fixture="$(jq -nc --arg id "$plugin_id" --arg root "$root" '[{id: $id, scope: "project", enabled: true, projectPath: $root}]')"
  run_probe_fixture "$fence" "$repository" "$stub_directory" "$fixture" || {
    echo "the probe failed the matching project-scope fixture" >&2
    return 1
  }
}

extract_obsidian_probe() {
  bash_fence_containing 'claude plugin list --json' "$PER_MACHINE_REFERENCE" >"${BATS_TEST_TMPDIR}/probe.sh"
  [ -s "${BATS_TEST_TMPDIR}/probe.sh" ]
}

@test "the claude-obsidian probe passes only a project-scope record for this repository root" {
  extract_obsidian_probe
  assert_probe_behavior "${BATS_TEST_TMPDIR}/probe.sh"
}

@test "probe mutation: a fence without the projectPath clause passes the other-path fixture" {
  extract_obsidian_probe
  local mutated="${BATS_TEST_TMPDIR}/probe-no-path.sh"
  sed 's/ and \.projectPath == \$root//' "${BATS_TEST_TMPDIR}/probe.sh" >"$mutated"
  cmp -s "${BATS_TEST_TMPDIR}/probe.sh" "$mutated" && return 1
  run assert_probe_behavior "$mutated"
  [ "$status" -ne 0 ]
  grep -qF 'other-path' <<<"$output"
}

@test "probe mutation: a fence without the scope clause passes the user-with-path fixture" {
  extract_obsidian_probe
  local mutated="${BATS_TEST_TMPDIR}/probe-no-scope.sh"
  sed 's/ and \.scope == "project"//' "${BATS_TEST_TMPDIR}/probe.sh" >"$mutated"
  cmp -s "${BATS_TEST_TMPDIR}/probe.sh" "$mutated" && return 1
  run assert_probe_behavior "$mutated"
  [ "$status" -ne 0 ]
  grep -qF 'user-with-path' <<<"$output"
}

# ---------------------------------------------------------------------------
# The React Doctor skill lives under frontend/
# ---------------------------------------------------------------------------

REACT_DOCTOR_PROBE='[ -d frontend/.claude/skills/react-doctor ]'
OLD_REACT_DOCTOR_PROBE='[ -d .claude/skills/react-doctor ]'

# check_react_doctor_location <per-machine> <surface-file> <init>: the probe
# names the frontend location, and no file carries the root-level probe.
check_react_doctor_location() {
  local per_machine="$1" surface="$2" init="$3" file
  grep -qF -- "$REACT_DOCTOR_PROBE" "$per_machine" || {
    echo "the per-machine probe does not name frontend/.claude/skills/react-doctor" >&2
    return 1
  }
  for file in "$surface" "$init"; do
    if grep -qF -- "$OLD_REACT_DOCTOR_PROBE" "$file"; then
      echo "${file} carries the root-level React Doctor probe" >&2
      return 1
    fi
  done
}

@test "the React Doctor probe names the frontend location and the old probe is gone" {
  check_react_doctor_location "$PER_MACHINE_REFERENCE" "$(real_surface)" "$INIT_PAGE"
}

@test "the React Doctor location check fails with the old probe put back in a reference" {
  local directory surface
  directory="$(scratch_references react-doctor-old-reference)"
  printf '\n%s\n' "$OLD_REACT_DOCTOR_PROBE" >>"${directory}/sandbox.md"
  surface="$(build_surface "$PAGE" "$directory" surface-react-doctor-old.md)"
  run check_react_doctor_location "${directory}/per-machine.md" "$surface" "$INIT_PAGE"
  [ "$status" -ne 0 ]
  grep -qF 'root-level React Doctor probe' <<<"$output"
}

@test "the React Doctor location check fails with the old probe put back in the init command" {
  local copy
  copy="$(scratch_copy "$INIT_PAGE" "react-doctor-old-init.md")"
  printf '\n%s\n' "$OLD_REACT_DOCTOR_PROBE" >>"$copy"
  run check_react_doctor_location "$PER_MACHINE_REFERENCE" "$(real_surface)" "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'root-level React Doctor probe' <<<"$output"
}

@test "the React Doctor location check fails when the per-machine probe loses the frontend path" {
  local copy
  copy="$(scratch_copy "$PER_MACHINE_REFERENCE" "react-doctor-no-frontend.md")"
  sed 's#\[ -d frontend/\.claude/skills/react-doctor \]#[ -d .claude/skills/react-doctor ]#' "$PER_MACHINE_REFERENCE" >"$copy"
  cmp -s "$PER_MACHINE_REFERENCE" "$copy" && return 1
  run check_react_doctor_location "$copy" "$(real_surface)" "$INIT_PAGE"
  [ "$status" -ne 0 ]
  grep -qF 'does not name' <<<"$output"
}
