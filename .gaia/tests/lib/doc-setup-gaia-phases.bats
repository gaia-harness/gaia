#!/usr/bin/env bats
# Static and executable checks over `.claude/commands/setup-gaia.md`, the
# onboarding command an agent reads and runs phase by phase, and over the
# references under `.claude/skills/gaia/references/setup/` that it loads one
# gated body at a time. The "setup surface" is the command followed by every
# reference in the expected-file list, so text that moved into a reference
# stays covered.
#
# The command carries no CI-wiring or per-developer audit-mode phase. What it
# keeps, and what this suite pins:
#
#   - No CI phase heading, no removed CLI verb, no CI token or tool-mode
#     question, anywhere on the surface.
#   - `--reconfigure` is parsed, and `RECONFIGURE` is consulted only by the
#     decisions it re-opens (Phase 2 sandbox, Phase 3.5 isolation policy,
#     Phase 3.7 squash-only merges, Phase 4.6 statusline left side) and the Phase 6
#     ping classification. Every gate stays in the command: no reference
#     mentions `RECONFIGURE`.
#   - Every team-setting read and commit on the surface targets
#     `.gaia/project.json`, and so does the isolation policy read in the shared
#     isolation reference.
#   - Every `Phase N` cross-reference names a phase heading of the command.
#   - The `GAIA-Audit` registration fence, extracted from the command and run
#     against a stubbed `gh`, adds `GAIA-Audit`, keeps every sibling context,
#     drops the stale `code-review-audit` context, and sends no PUT when
#     nothing is owed. The registration and protection fences each exist
#     exactly once across the surface.
#   - The Dependabot posture step in the GitHub repository reference warns and
#     never edits.
#   - The reference index: the directory, the command's references block and
#     its "Read ... now" lines name the same files, one level deep, under the
#     line cap, each long file carrying a `Contents:` line in the frozen form.
#   - One per-machine source: the install literals live in the per-machine
#     reference or the React Doctor installer script, never in either command.
#   - claude-obsidian installs at project scope: the install lines, the
#     committed settings, and the probe executed against a stubbed `claude`.
#   - The React Doctor skill lives under `frontend/`.
#
# Each check is a function over a file path, so every test that proves the
# real page passes has a twin that runs the same function over a scratch copy
# with the forbidden content put back and asserts it fails.
#
# Tokens the removed-automation guard forbids anywhere in the tree are built
# at runtime (printf or concatenation) so this file never carries one.
#
# Assertion style: .claude/rules/bats-assertions.md.

# Each reference basename is named literally, once, in this list: the change
# selector picks this suite only when it contains a changed file's basename.
# The reference-index check keeps the list and the directory in step.
EXPECTED_SETUP_REFERENCES="per-machine.md sandbox.md github-repo.md isolation-question.md squash-only.md statusline-left.md"

# The exact opening sentence of a command's references block.
REFERENCES_OPENING='This command reads these references, all under `.claude/skills/gaia/references/setup/`. Read one only when a "Read ... now" line sends you there, and then read the whole file:'

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/.claude/commands/setup-gaia.md"
  INIT_PAGE="${REPO_ROOT}/.claude/commands/gaia-init.md"
  ISOLATION_REFERENCE="${REPO_ROOT}/.claude/skills/gaia/references/isolation.md"
  REFERENCES_DIRECTORY="${REPO_ROOT}/.claude/skills/gaia/references/setup"
  GITHUB_REPO_REFERENCE="${REFERENCES_DIRECTORY}/github-repo.md"
  PER_MACHINE_REFERENCE="${REFERENCES_DIRECTORY}/per-machine.md"
  REACT_DOCTOR_INSTALLER="${REPO_ROOT}/.gaia/scripts/install-react-doctor.sh"
  SETTINGS_FILE="${REPO_ROOT}/.claude/settings.json"
  [ -f "$PAGE" ] || {
    echo "the audited page is absent: ${PAGE}" >&2
    return 1
  }
  [ -f "$INIT_PAGE" ] || {
    echo "the init page is absent: ${INIT_PAGE}" >&2
    return 1
  }
  [ -f "$ISOLATION_REFERENCE" ] || {
    echo "the isolation reference is absent: ${ISOLATION_REFERENCE}" >&2
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
# No CI phases
# ---------------------------------------------------------------------------

# forbidden_literals: one forbidden fixed string per line.
forbidden_literals() {
  printf '%s\n' \
    '## Phase 4:' \
    '## Phase 5:' \
    'audit-mode-decision' \
    'setup-ci status' \
    'check-drift' \
    'check-audit-drift' \
    'dismiss-personal' \
    'opt-out-team' \
    'verify-run' \
    'setup-ci finalize' \
    'write-tool-mode' \
    'CLAUDE_CODE_OAUTH_TOKEN' \
    'ANTHROPIC_API_KEY' \
    'default_mode'
  printf 'write-dependabot-%s\n' config policy
  printf 'enable-dependabot-%s\n' security
  printf 'automation%sjson\n' .
  printf 'claude-code%saction\n' -
  printf 'docs.gaiareact.com/maintenance/gaia%sci\n' -
}

# check_no_ci_phases <file>: fails, naming the hit, when the file carries any
# forbidden literal or a CI enable, token-type, or tool-mode question.
check_no_ci_phases() {
  local file="$1" literal count=0
  while IFS= read -r literal; do
    count=$((count + 1))
    if grep -qF -- "$literal" "$file"; then
      echo "forbidden literal present: ${literal}" >&2
      return 1
    fi
  done < <(forbidden_literals)
  # A short read of the literal list would turn the loop into a partial check.
  [ "$count" -eq 20 ] || {
    echo "expected 20 forbidden literals, read ${count}" >&2
    return 1
  }
  if grep -qiE 'enable gaia ci|which bot token|token type|tool mode|tools running on cron' "$file"; then
    echo "a CI enable, token-type, or tool-mode question is present" >&2
    return 1
  fi
}

@test "setup-gaia and its references carry no CI phase, removed verb, token, or tool-mode question" {
  check_no_ci_phases "$(real_surface)"
}

@test "the no-CI check over the surface fails on a literal put back in a reference" {
  local directory surface
  directory="$(scratch_references no-ci-reference)"
  printf '\n%s\n' 'ANTHROPIC_API_KEY' >>"${directory}/sandbox.md"
  surface="$(build_surface "$PAGE" "$directory" surface-no-ci.md)"
  run check_no_ci_phases "$surface"
  [ "$status" -ne 0 ]
}

@test "the no-CI check fails on every forbidden literal put back" {
  local literal count=0 copy
  while IFS= read -r literal; do
    count=$((count + 1))
    copy="$(scratch_copy "$PAGE" "no-ci-${count}.md")"
    printf '\n%s\n' "$literal" >>"$copy"
    run check_no_ci_phases "$copy"
    [ "$status" -ne 0 ] || {
      echo "the check passed with ${literal} present" >&2
      return 1
    }
  done < <(forbidden_literals)
  [ "$count" -eq 20 ]
}

@test "the no-CI check fails on a CI enable question put back" {
  local copy
  copy="$(scratch_copy "$PAGE" "no-ci-question.md")"
  printf '\n> Enable GAIA CI now?\n' >>"$copy"
  run check_no_ci_phases "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# --reconfigure stays, scoped to its decisions and the ping
# ---------------------------------------------------------------------------

# check_reconfigure_scope <file>: the argument parse names --reconfigure and
# caches RECONFIGURE, and every other RECONFIGURE line sits under Phase 2,
# 3.5, 3.7, 4.6, or 6.
check_reconfigure_scope() {
  local file="$1" parse_section stray
  parse_section="$(awk '/^## /{inside = ($0 == "## Argument parse")} inside' "$file")"
  grep -qF -- '--reconfigure' <<<"$parse_section" || {
    echo "the argument parse no longer names --reconfigure" >&2
    return 1
  }
  grep -qF -- 'RECONFIGURE' <<<"$parse_section" || {
    echo "the argument parse no longer caches RECONFIGURE" >&2
    return 1
  }
  stray="$(awk '
    /^## / { heading = $0 }
    /RECONFIGURE/ {
      if (heading == "## Argument parse") next
      if (heading ~ /^## Phase (2|3\.5|3\.7|4\.6|6):/) next
      print NR ": " heading
    }
  ' "$file")"
  [ -z "$stray" ] || {
    echo "RECONFIGURE outside its phases: ${stray}" >&2
    return 1
  }
}

@test "--reconfigure is parsed and RECONFIGURE is read only in Phases 2, 3.5, 3.7, 4.6, and 6" {
  check_reconfigure_scope "$PAGE"
}

@test "the reconfigure check fails on RECONFIGURE under another phase" {
  local copy
  copy="$(scratch_copy "$PAGE" "reconfigure-stray.md")"
  awk '{ print } /^## Phase 4\.5:/ { print ""; print "When `RECONFIGURE` is set, rotate the token." }' \
    "$PAGE" >"$copy"
  run check_reconfigure_scope "$copy"
  [ "$status" -ne 0 ]
}

@test "the reconfigure check fails when the argument parse drops the flag" {
  local copy
  copy="$(scratch_copy "$PAGE" "reconfigure-unparsed.md")"
  awk '/^## /{inside = ($0 == "## Argument parse")} inside && /RECONFIGURE/ { next } { print }' \
    "$PAGE" >"$copy"
  run check_reconfigure_scope "$copy"
  [ "$status" -ne 0 ]
}

# check_references_never_reconfigure <directory>: no reference mentions
# RECONFIGURE, because every gate that consults it stays in the command.
check_references_never_reconfigure() {
  local directory="$1" file count=0
  for file in "${directory}"/*.md; do
    [ -f "$file" ] || continue
    count=$((count + 1))
    if grep -qF -- 'RECONFIGURE' "$file"; then
      echo "a reference mentions RECONFIGURE: ${file}" >&2
      return 1
    fi
  done
  [ "$count" -gt 0 ] || {
    echo "no reference found in ${directory}" >&2
    return 1
  }
}

@test "no setup reference mentions RECONFIGURE" {
  check_references_never_reconfigure "$REFERENCES_DIRECTORY"
}

@test "the reference RECONFIGURE check fails on a mention appended to a reference copy" {
  local directory
  directory="$(scratch_references reconfigure-reference)"
  printf '\nWhen `RECONFIGURE` is set, ask again.\n' >>"${directory}/squash-only.md"
  run check_references_never_reconfigure "$directory"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Team settings live in .gaia/project.json
# ---------------------------------------------------------------------------

# check_project_json <file>: every jq read of a .gaia/*.json file targets
# .gaia/project.json, the expected keys are read from it, and the one
# team-setting commit stages it. A read of .gaia/local/settings.json is not a
# team setting: it is the per-machine opt-ins file (the statusline left-side
# choice), so it is left out of the read set.
check_project_json() {
  local file="$1" reads stray key staged
  reads="$(grep -E "jq -r '[^']*' \.gaia/[^ ]*\.json" "$file" | grep -vF "' .gaia/local/settings.json" || true)"
  [ -n "$reads" ] || {
    echo "no jq read of a .gaia/*.json file found" >&2
    return 1
  }
  stray="$(grep -vF '.gaia/project.json' <<<"$reads" || true)"
  [ -z "$stray" ] || {
    echo "a key read targets another file: ${stray}" >&2
    return 1
  }
  for key in sandbox_recommended isolation_policy; do
    grep -qF -- "$key" <<<"$reads" || {
      echo "no .gaia/project.json read for ${key}" >&2
      return 1
    }
  done
  staged="$(grep -cE '^git add \.gaia/project\.json' "$file" || true)"
  [ "$staged" -eq 1 ] || {
    echo "expected 1 commit staging .gaia/project.json, found ${staged}" >&2
    return 1
  }
}

@test "every team-setting read and commit on the setup surface targets .gaia/project.json" {
  check_project_json "$(real_surface)"
}

@test "the project.json check fails on a read of another config file" {
  local copy surface
  copy="$(scratch_copy "$PAGE" "project-json-read.md")"
  sed "s#has(\"isolation_policy\")' \.gaia/project\.json#has(\"isolation_policy\")' .gaia/other.json#" \
    "$PAGE" >"$copy"
  grep -qF '.gaia/other.json' "$copy"
  surface="$(build_surface "$copy" "$REFERENCES_DIRECTORY" surface-project-json-read.md)"
  run check_project_json "$surface"
  [ "$status" -ne 0 ]
}

@test "the project.json check fails when a commit stages another file" {
  local copy surface
  copy="$(scratch_copy "$PAGE" "project-json-commit.md")"
  awk '/^git add \.gaia\/project\.json/ && !done { sub(/project\.json/, "other.json"); done = 1 } { print }' \
    "$PAGE" >"$copy"
  cmp -s "$PAGE" "$copy" && return 1
  surface="$(build_surface "$copy" "$REFERENCES_DIRECTORY" surface-project-json-commit.md)"
  run check_project_json "$surface"
  [ "$status" -ne 0 ]
}

@test "the project.json check fails when the sandbox reference reads another file" {
  local directory surface
  directory="$(scratch_references project-json-sandbox)"
  sed "s#sandbox_recommended // false' \.gaia/project\.json#sandbox_recommended // false' .gaia/other.json#" \
    "${REFERENCES_DIRECTORY}/sandbox.md" >"${directory}/sandbox.md"
  cmp -s "${REFERENCES_DIRECTORY}/sandbox.md" "${directory}/sandbox.md" && return 1
  surface="$(build_surface "$PAGE" "$directory" surface-project-json-sandbox.md)"
  run check_project_json "$surface"
  [ "$status" -ne 0 ]
}

# check_isolation_reference <file>: the policy read targets
# .gaia/project.json with its load-bearing fallback tail, and the file names
# no automation config anywhere.
check_isolation_reference() {
  local file="$1"
  grep -qF -- "jq -r '.isolation_policy // \"prefer-branch\"' .gaia/project.json 2>/dev/null || echo prefer-branch" "$file" || {
    echo "the policy read does not target .gaia/project.json with its fallback tail" >&2
    return 1
  }
  if grep -n 'automation' "$file"; then
    echo "the isolation reference still mentions automation" >&2
    return 1
  fi
}

@test "the isolation reference reads its policy from .gaia/project.json" {
  check_isolation_reference "$ISOLATION_REFERENCE"
}

@test "the isolation check fails on the old config path put back" {
  local copy
  copy="$(scratch_copy "$ISOLATION_REFERENCE" "isolation-old.md")"
  sed "s#\.gaia/project\.json#.gaia/$(printf 'automation%sjson' .)#" "$ISOLATION_REFERENCE" >"$copy"
  run check_isolation_reference "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Cross-references resolve
# ---------------------------------------------------------------------------

# check_phase_references <surface-file> <entry-file>: every "Phase N" or
# "Phase N.N" mention on the surface names a "## Phase N:" heading that exists
# in the entry command, the only file whose headings are phases.
check_phase_references() {
  local file="$1" entry="$2" referenced phase missing="" count=0
  referenced="$(grep -oE 'Phase [0-9]+(\.[0-9]+)?' "$file" | sort -u)"
  [ -n "$referenced" ] || {
    echo "no phase reference found" >&2
    return 1
  }
  while IFS= read -r phase; do
    count=$((count + 1))
    grep -qE "^## ${phase//./\\.}:" "$entry" || missing="${missing} ${phase}"
  done <<<"$referenced"
  [ -z "$missing" ] || {
    echo "phase references with no heading:${missing}" >&2
    return 1
  }
  [ "$count" -ge 7 ]
}

@test "every Phase cross-reference on the setup surface names an existing phase heading" {
  check_phase_references "$(real_surface)" "$PAGE"
}

@test "the cross-reference check fails on a reference to a removed phase" {
  local copy surface
  copy="$(scratch_copy "$PAGE" "phase-reference.md")"
  printf '\nFall through to Phase 5.\n' >>"$copy"
  surface="$(build_surface "$copy" "$REFERENCES_DIRECTORY" surface-phase-reference.md)"
  run check_phase_references "$surface" "$copy"
  [ "$status" -ne 0 ]
}

@test "the cross-reference check fails on a reference file naming a missing phase" {
  local directory surface
  directory="$(scratch_references phase-reference-directory)"
  printf '\nContinue at Phase 5.\n' >>"${directory}/squash-only.md"
  surface="$(build_surface "$PAGE" "$directory" surface-phase-reference-file.md)"
  run check_phase_references "$surface" "$PAGE"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The GAIA-Audit registration fence, executed against a stubbed gh
# ---------------------------------------------------------------------------

REGISTRATION_ANCHOR='required_checks_endpoint='

# registration_fence <file>: print the body of the one bash fence containing
# the registration anchor.
registration_fence() {
  awk -v anchor="$REGISTRATION_ANCHOR" '
    /^```bash[[:space:]]*$/ { inside = 1; body = ""; next }
    /^```[[:space:]]*$/ && inside {
      inside = 0
      if (index(body, anchor)) { printf "%s", body; found++ }
      next
    }
    inside { body = body $0 "\n" }
    END { if (found != 1) exit 1 }
  ' "$1"
}

# run_fence <fence-file> <contexts-json>: run the fence with a gh stub on PATH
# that logs every call to ${BATS_TEST_TMPDIR}/gh.log and answers the GET with
# the given contexts array.
run_fence() {
  local fence="$1" contexts="$2" stub_directory="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "$stub_directory"
  cat >"${stub_directory}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case " $* " in
  *" -X PUT "*) cat >"$GH_BODY"; exit 0 ;;
esac
printf '%s\n' "$GH_CONTEXTS_FIXTURE"
STUB
  chmod +x "${stub_directory}/gh"
  : >"${BATS_TEST_TMPDIR}/gh.log"
  : >"${BATS_TEST_TMPDIR}/gh.body"
  GH_LOG="${BATS_TEST_TMPDIR}/gh.log" GH_BODY="${BATS_TEST_TMPDIR}/gh.body" GH_CONTEXTS_FIXTURE="$contexts" \
    PATH="${stub_directory}:${PATH}" bash "$fence"
}

# put_line: the one logged PUT call, empty when none was sent. put_body is the
# JSON the call piped to `--input -`.
put_line() {
  grep -E -- '(^| )-X PUT ' "${BATS_TEST_TMPDIR}/gh.log" || true
}

# assert_stale_context_dropped <fence-file>: fixture 1. The GET reports the
# stale context beside a sibling; the PUT carries GAIA-Audit and the sibling
# and not the stale context.
assert_stale_context_dropped() {
  local stale="code-review-audit" put
  run_fence "$1" "[\"${stale}\", \"Vitest\"]" || return 1
  put="$(put_line)"
  [ "$(grep -cE -- '(^| )-X PUT ' "${BATS_TEST_TMPDIR}/gh.log")" -eq 1 ] || {
    echo "expected exactly one PUT" >&2
    return 1
  }
  grep -qF -- '/protection/required_status_checks/contexts --input -' <<<"$put" || {
    echo "the PUT does not target the /contexts endpoint: ${put}" >&2
    return 1
  }
  jq -e 'any(.contexts[]; . == "GAIA-Audit") and any(.contexts[]; . == "Vitest")' "${BATS_TEST_TMPDIR}/gh.body" >/dev/null || return 1
  if jq -e --arg stale "$stale" 'any(.contexts[]; . == $stale)' "${BATS_TEST_TMPDIR}/gh.body" >/dev/null; then
    echo "the PUT body still carries the stale context: $(cat "${BATS_TEST_TMPDIR}/gh.body")" >&2
    return 1
  fi
}

extract_registration_fence() {
  registration_fence "$PAGE" >"${BATS_TEST_TMPDIR}/fence.sh"
  [ -s "${BATS_TEST_TMPDIR}/fence.sh" ]
}

@test "registration fixture 1: a stale code-review-audit context is dropped, siblings kept, GAIA-Audit added" {
  extract_registration_fence
  assert_stale_context_dropped "${BATS_TEST_TMPDIR}/fence.sh"
}

@test "registration fixture 2: GAIA-Audit already required and nothing stale sends no PUT" {
  extract_registration_fence
  run_fence "${BATS_TEST_TMPDIR}/fence.sh" '["GAIA-Audit", "Vitest"]'
  [ "$(wc -l <"${BATS_TEST_TMPDIR}/gh.log" | tr -d ' ')" -eq 1 ]
  [ -z "$(put_line)" ]
}

@test "registration fixture 3: GAIA-Audit is added beside an existing sibling" {
  extract_registration_fence
  run_fence "${BATS_TEST_TMPDIR}/fence.sh" '["Vitest"]'
  local put
  put="$(put_line)"
  [ -n "$put" ]
  jq -e '.contexts == ["Vitest", "GAIA-Audit"]' "${BATS_TEST_TMPDIR}/gh.body" >/dev/null
}

@test "registration: a failed GET sends no PUT" {
  extract_registration_fence
  local stub_directory="${BATS_TEST_TMPDIR}/failing-bin"
  mkdir -p "$stub_directory"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$GH_LOG"\nexit 1\n' >"${stub_directory}/gh"
  chmod +x "${stub_directory}/gh"
  : >"${BATS_TEST_TMPDIR}/gh.log"
  GH_LOG="${BATS_TEST_TMPDIR}/gh.log" PATH="${stub_directory}:${PATH}" \
    bash "${BATS_TEST_TMPDIR}/fence.sh" 2>/dev/null
  [ "$(wc -l <"${BATS_TEST_TMPDIR}/gh.log" | tr -d ' ')" -eq 1 ]
  [ -z "$(put_line)" ]
}

@test "registration mutation: the fence without the drop filter fails fixture 1" {
  extract_registration_fence
  local mutated="${BATS_TEST_TMPDIR}/fence-no-drop.sh"
  sed 's/map(select(\. != "code-review-audit" and \. != "GAIA-Audit"))/map(select(. != "GAIA-Audit"))/' \
    "${BATS_TEST_TMPDIR}/fence.sh" >"$mutated"
  # The mutation must actually change the fence, or this test proves nothing.
  cmp -s "${BATS_TEST_TMPDIR}/fence.sh" "$mutated" && return 1
  run assert_stale_context_dropped "$mutated"
  [ "$status" -ne 0 ]
}

@test "registration mutation: a fence that PUTs to the bare endpoint fails fixture 1" {
  extract_registration_fence
  local mutated="${BATS_TEST_TMPDIR}/fence-bare-endpoint.sh"
  sed 's#"\$required_checks_endpoint/contexts"#"$required_checks_endpoint"#' \
    "${BATS_TEST_TMPDIR}/fence.sh" >"$mutated"
  cmp -s "${BATS_TEST_TMPDIR}/fence.sh" "$mutated" && return 1
  run assert_stale_context_dropped "$mutated"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The default-branch protection fence, executed against a stubbed gh
# ---------------------------------------------------------------------------
# The full protection PUT replaces every setting on an existing rule, so the
# fence must send it only when the probe finds no rule (gaia-react/gaia#2412).

PROTECTION_ANCHOR='protection_endpoint='

extract_protection_fence() {
  awk -v anchor="$PROTECTION_ANCHOR" '
    /^```bash[[:space:]]*$/ { inside = 1; body = ""; next }
    /^```[[:space:]]*$/ && inside {
      inside = 0
      if (index(body, anchor)) { printf "%s", body; found++ }
      next
    }
    inside { body = body $0 "\n" }
    END { if (found != 1) exit 1 }
  ' "$PAGE" >"${BATS_TEST_TMPDIR}/protection.sh"
  [ -s "${BATS_TEST_TMPDIR}/protection.sh" ]
}

# run_protection_fence <fence-file> <get-exit-status>: run the fence with a gh
# stub that logs every call and answers the protection GET with the given exit
# status (0: a rule exists, 1: none does).
run_protection_fence() {
  local stub_directory="${BATS_TEST_TMPDIR}/protection-bin"
  mkdir -p "$stub_directory"
  cat >"${stub_directory}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case " $* " in
  *" -X PUT "*) cat >"$GH_BODY"; exit 0 ;;
esac
exit "$GH_PROTECTION_GET_STATUS"
STUB
  chmod +x "${stub_directory}/gh"
  : >"${BATS_TEST_TMPDIR}/gh.log"
  : >"${BATS_TEST_TMPDIR}/gh.body"
  GH_LOG="${BATS_TEST_TMPDIR}/gh.log" GH_BODY="${BATS_TEST_TMPDIR}/gh.body" GH_PROTECTION_GET_STATUS="$2" \
    PATH="${stub_directory}:${PATH}" bash "$1" >/dev/null
}

@test "protection fixture: an existing rule is kept and no protection PUT is sent" {
  extract_protection_fence
  run_protection_fence "${BATS_TEST_TMPDIR}/protection.sh" 0
  [ "$(wc -l <"${BATS_TEST_TMPDIR}/gh.log" | tr -d ' ')" -eq 1 ]
  [ -z "$(put_line)" ]
}

@test "protection fixture: with no rule, exactly one full protection PUT is sent" {
  extract_protection_fence
  run_protection_fence "${BATS_TEST_TMPDIR}/protection.sh" 1
  [ "$(grep -cE -- '(^| )-X PUT ' "${BATS_TEST_TMPDIR}/gh.log")" -eq 1 ]
  grep -qE -- '/branches/<default-branch>/protection --input -$' <<<"$(put_line)"
  jq -e '.enforce_admins == false and .required_status_checks.contexts == []' "${BATS_TEST_TMPDIR}/gh.body" >/dev/null
}

@test "protection mutation: an unconditional PUT fails the existing-rule fixture" {
  extract_protection_fence
  local mutated="${BATS_TEST_TMPDIR}/protection-unconditional.sh"
  sed 's#^if gh api "\$protection_endpoint" >/dev/null 2>&1; then#if false; then#' \
    "${BATS_TEST_TMPDIR}/protection.sh" >"$mutated"
  cmp -s "${BATS_TEST_TMPDIR}/protection.sh" "$mutated" && return 1
  run_protection_fence "$mutated" 0
  [ -n "$(put_line)" ]
}

# fence_count_across_surface <anchor> <entry> <directory>: print how many bash
# fences containing the anchor the whole surface carries.
fence_count_across_surface() {
  local anchor="$1" file total=0 count files
  files="$(surface_files "$2" "$3")" || return 1
  while IFS= read -r file; do
    count="$(awk -v anchor="$anchor" '
      /^```bash[[:space:]]*$/ { inside = 1; body = ""; next }
      /^```[[:space:]]*$/ && inside {
        inside = 0
        if (index(body, anchor)) { found++ }
        next
      }
      inside { body = body $0 "\n" }
      END { print found + 0 }
    ' "$file")"
    total=$((total + count))
  done <<<"$files"
  printf '%s\n' "$total"
}

# check_fences_single_source <entry> <directory>: the registration fence and
# the protection fence each exist exactly once across the surface, and the one
# copy sits in the entry command.
check_fences_single_source() {
  local entry="$1" directory="$2" anchor total in_entry
  for anchor in "$REGISTRATION_ANCHOR" "$PROTECTION_ANCHOR"; do
    total="$(fence_count_across_surface "$anchor" "$entry" "$directory")" || return 1
    [ "$total" -eq 1 ] || {
      echo "expected exactly one fence carrying ${anchor} across the surface, found ${total}" >&2
      return 1
    }
    in_entry="$(awk -v anchor="$anchor" '
      /^```bash[[:space:]]*$/ { inside = 1; body = ""; next }
      /^```[[:space:]]*$/ && inside { inside = 0; if (index(body, anchor)) found++; next }
      inside { body = body $0 "\n" }
      END { print found + 0 }
    ' "$entry")"
    [ "$in_entry" -eq 1 ] || {
      echo "the fence carrying ${anchor} is not in the entry command" >&2
      return 1
    }
  done
}

@test "the registration and protection fences each exist once across the surface, in the command" {
  check_fences_single_source "$PAGE" "$REFERENCES_DIRECTORY"
}

@test "the single-fence check fails on a second registration fence in a reference" {
  local directory
  directory="$(scratch_references second-registration-fence)"
  printf '\n```bash\n%s"x"\n```\n' "$REGISTRATION_ANCHOR" >>"${directory}/github-repo.md"
  run check_fences_single_source "$PAGE" "$directory"
  [ "$status" -ne 0 ]
}

@test "the single-fence check fails on a second protection fence in a reference" {
  local directory
  directory="$(scratch_references second-protection-fence)"
  printf '\n```bash\n%s"x"\n```\n' "$PROTECTION_ANCHOR" >>"${directory}/github-repo.md"
  run check_fences_single_source "$PAGE" "$directory"
  [ "$status" -ne 0 ]
}

@test "the single-fence check fails when the fence moves out of the command" {
  local copy
  copy="$(scratch_copy "$PAGE" "fence-moved-out.md")"
  sed "s#${REGISTRATION_ANCHOR}#registration_moved=#" "$PAGE" >"$copy"
  cmp -s "$PAGE" "$copy" && return 1
  run check_fences_single_source "$copy" "$REFERENCES_DIRECTORY"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Dependabot is a data source: no opt-in question, no config write
# ---------------------------------------------------------------------------

# check_no_dependabot_question <file>: fails when the page asks a Dependabot
# question or carries the retired opt-in phase heading.
check_no_dependabot_question() {
  local file="$1"
  grep -qE 'header \*\*`Dependabot`\*\*' "$file" && {
    echo "a Dependabot AskUserQuestion is present" >&2
    return 1
  }
  grep -qE '^## Phase 3\.6' "$file" && {
    echo "the retired Phase 3.6 heading is present" >&2
    return 1
  }
  return 0
}

@test "setup-gaia and its references ask no Dependabot question and have no Phase 3.6" {
  check_no_dependabot_question "$(real_surface)"
}

@test "the no-Dependabot-question check fails on the question put back in a reference" {
  local directory surface
  directory="$(scratch_references dependabot-question-reference)"
  printf '\nUse `AskUserQuestion`, header **`Dependabot`**, with two options.\n' >>"${directory}/github-repo.md"
  surface="$(build_surface "$PAGE" "$directory" surface-dependabot-question.md)"
  run check_no_dependabot_question "$surface"
  [ "$status" -ne 0 ]
}

@test "the no-Dependabot-question check fails on the question put back" {
  local copy
  copy="$(scratch_copy "$PAGE" "dependabot-question.md")"
  printf '\nUse `AskUserQuestion`, header **`Dependabot`**, with two options.\n' >>"$copy"
  run check_no_dependabot_question "$copy"
  [ "$status" -ne 0 ]
}

@test "the no-Dependabot-question check fails on the Phase 3.6 heading put back" {
  local copy
  copy="$(scratch_copy "$PAGE" "dependabot-heading.md")"
  printf '\n## Phase 3.6: Dependabot security updates\n' >>"$copy"
  run check_no_dependabot_question "$copy"
  [ "$status" -ne 0 ]
}

# check_posture_subcommand <file>: the page invokes the posture subcommand.
check_posture_subcommand() {
  grep -qF -- 'setup configure-dependabot-alerts' "$1" || {
    echo "the page does not invoke setup configure-dependabot-alerts" >&2
    return 1
  }
}

@test "the posture step calls the configure-dependabot-alerts subcommand" {
  check_posture_subcommand "$GITHUB_REPO_REFERENCE"
}

@test "the posture-subcommand check fails when the call is removed" {
  local copy
  copy="$(scratch_copy "$GITHUB_REPO_REFERENCE" "posture-call-removed.md")"
  grep -vF -- 'setup configure-dependabot-alerts' "$GITHUB_REPO_REFERENCE" >"$copy" || true
  cmp -s "$GITHUB_REPO_REFERENCE" "$copy" && return 1
  run check_posture_subcommand "$copy"
  [ "$status" -ne 0 ]
}

@test "the no-CI check fails when the Dependabot config writer is put back" {
  local copy literal
  literal="$(printf 'write-dependabot-%s' config)"
  copy="$(scratch_copy "$PAGE" "writer-put-back.md")"
  printf '\n.gaia/cli/gaia setup %s --json\n' "$literal" >>"$copy"
  run check_no_ci_phases "$copy"
  [ "$status" -ne 0 ]
}

@test "the project.json check fails when a second team-setting commit is added" {
  local copy surface
  copy="$(scratch_copy "$PAGE" "second-commit.md")"
  printf '\n```bash\ngit add .gaia/project.json\n```\n' >>"$copy"
  surface="$(build_surface "$copy" "$REFERENCES_DIRECTORY" surface-second-commit.md)"
  run check_project_json "$surface"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The Dependabot posture step warns and never edits
# ---------------------------------------------------------------------------

# posture_section <file>: the posture step's text, from its bold lead-in to the
# next level-two heading.
posture_section() {
  awk '
    /^## / { inside = 0 }
    /^\*\*Dependabot posture\.\*\*/ { inside = 1 }
    inside
  ' "$1"
}

# check_posture_warns_only <file>: passes only when the posture step invokes
# warn-existing-tools, tells the human to delete the npm entry, tells the human
# to disable Renovate's npm and pnpm management, and instructs no write,
# create, or edit of .github/dependabot.yml. The removal step is phrased with
# "delete", the refusals avoid those verbs, and "writes" (as in "GAIA writes
# no ...") is a different word, so only an imperative write, create, or edit
# verb on a line naming dependabot.yml counts as an edit instruction.
check_posture_warns_only() {
  local section
  section="$(posture_section "$1")"
  [ -n "$section" ] || {
    echo "the posture step is absent" >&2
    return 1
  }
  grep -qF -- 'setup warn-existing-tools' <<<"$section" || {
    echo "the posture step does not invoke warn-existing-tools" >&2
    return 1
  }
  grep -qE 'delete the `package-ecosystem: npm` entry from \.github/dependabot\.yml' <<<"$section" || {
    echo "the posture step does not tell the human to delete the npm entry" >&2
    return 1
  }
  grep -E 'disable Renovate' <<<"$section" | grep -qF 'npm and pnpm' || {
    echo "the posture step carries no Renovate warning naming the disable step" >&2
    return 1
  }
  if grep -iE 'dependabot\.ya?ml' <<<"$section" | grep -qiE '(^|[^a-z])(write|create|edit)([^a-z]|$)'; then
    echo "the posture step instructs a write, create, or edit of dependabot.yml" >&2
    return 1
  fi
  return 0
}

@test "the posture step warns about existing tools and never edits their files" {
  check_posture_warns_only "$GITHUB_REPO_REFERENCE"
}

@test "the posture check fails when the warn-existing-tools call is removed" {
  local copy
  copy="$(scratch_copy "$GITHUB_REPO_REFERENCE" "posture-no-warn.md")"
  grep -vF -- 'setup warn-existing-tools' "$GITHUB_REPO_REFERENCE" >"$copy" || true
  cmp -s "$GITHUB_REPO_REFERENCE" "$copy" && return 1
  run check_posture_warns_only "$copy"
  [ "$status" -ne 0 ]
}

@test "the posture check fails when the npm entry removal sentence is removed" {
  local copy
  copy="$(scratch_copy "$GITHUB_REPO_REFERENCE" "posture-no-removal.md")"
  grep -vF -- 'package-ecosystem: npm' "$GITHUB_REPO_REFERENCE" >"$copy" || true
  cmp -s "$GITHUB_REPO_REFERENCE" "$copy" && return 1
  run check_posture_warns_only "$copy"
  [ "$status" -ne 0 ]
}

@test "the posture check fails when the Renovate warning is removed" {
  local copy
  copy="$(scratch_copy "$GITHUB_REPO_REFERENCE" "posture-no-renovate.md")"
  grep -vF -- 'disable Renovate' "$GITHUB_REPO_REFERENCE" >"$copy" || true
  cmp -s "$GITHUB_REPO_REFERENCE" "$copy" && return 1
  run check_posture_warns_only "$copy"
  [ "$status" -ne 0 ]
}

@test "the posture check fails when an instruction to write dependabot.yml is inserted" {
  local copy
  copy="$(scratch_copy "$GITHUB_REPO_REFERENCE" "posture-writes.md")"
  awk '{ print } /^\*\*Dependabot posture\.\*\*/ { print ""; print "Write .github/dependabot.yml with the npm entry." }' \
    "$GITHUB_REPO_REFERENCE" >"$copy"
  cmp -s "$GITHUB_REPO_REFERENCE" "$copy" && return 1
  run check_posture_warns_only "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The reference index: directory, references block and Read lines agree
# ---------------------------------------------------------------------------

SETUP_REFERENCES_PATH='.claude/skills/gaia/references/setup/'

# references_block_names <entry>: print the basenames of the bullets directly
# below the references block's exact opening sentence, one per line. Fails
# loudly when the opening sentence is absent, because the block cannot then be
# located.
references_block_names() {
  local entry="$1" names
  names="$(OPENING="$REFERENCES_OPENING" awk '
    $0 == ENVIRON["OPENING"] { found = 1; next }
    found && /^- `[^`]+\.md`: / {
      name = $0
      sub(/^- `/, "", name)
      sub(/`:.*$/, "", name)
      print name
      next
    }
    found { exit }
    END { if (!found) exit 2 }
  ' "$entry")" || {
    echo "the references block opening sentence is absent from ${entry}" >&2
    return 1
  }
  printf '%s\n' "$names"
}

# check_reference_index <entry> <directory>: the *.md files of the directory,
# the bullets of the entry's references block, and the expected list name the
# same files; the entry carries a "Read ... now" line for each, and every
# references/setup path it names exists.
check_reference_index() {
  local entry="$1" directory="$2" expected listed block name named file nested
  expected="$(tr ' ' '\n' <<<"$EXPECTED_SETUP_REFERENCES" | sort)"
  [ -n "$expected" ] || {
    echo "the expected reference list is empty" >&2
    return 1
  }
  listed="$(find "$directory" -maxdepth 1 -type f -name '*.md' -exec basename {} \; | sort)"
  [ "$listed" = "$expected" ] || {
    echo "the references directory differs from the expected list:" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") >&2 || true
    return 1
  }
  nested="$(find "$directory" -mindepth 1 -type d)"
  [ -z "$nested" ] || {
    echo "the references directory has a subdirectory: ${nested}" >&2
    return 1
  }
  block="$(references_block_names "$entry")" || return 1
  block="$(sort <<<"$block")"
  [ "$block" = "$expected" ] || {
    echo "the references block differs from the expected list:" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$block") >&2 || true
    return 1
  }
  for name in $EXPECTED_SETUP_REFERENCES; do
    grep -qF -- "Read \`${SETUP_REFERENCES_PATH}${name}\` now" "$entry" || {
      echo "the entry has no Read line for ${name}" >&2
      return 1
    }
  done
  named="$(grep -oE 'references/setup/[A-Za-z0-9._-]+\.md' "$entry" | sort -u)"
  [ -n "$named" ] || {
    echo "the entry names no references/setup path" >&2
    return 1
  }
  while IFS= read -r file; do
    [ -f "${directory}/${file#references/setup/}" ] || {
      echo "the entry names a missing reference: ${file}" >&2
      return 1
    }
  done <<<"$named"
}

@test "the setup reference directory, references block, and Read lines name the same files" {
  check_reference_index "$PAGE" "$REFERENCES_DIRECTORY"
}

@test "the reference index check fails on an unlisted file in the directory" {
  local directory
  directory="$(scratch_references index-extra-file)"
  printf '# Extra\n' >"${directory}/unlisted.md"
  run check_reference_index "$PAGE" "$directory"
  [ "$status" -ne 0 ]
  grep -qF 'differs from the expected list' <<<"$output"
}

@test "the reference index check fails when an expected file is missing from the directory" {
  local directory
  directory="$(scratch_references index-missing-file)"
  rm "${directory}/squash-only.md"
  run check_reference_index "$PAGE" "$directory"
  [ "$status" -ne 0 ]
  grep -qF 'differs from the expected list' <<<"$output"
}

@test "the reference index check fails when the entry names a missing file" {
  local copy
  copy="$(scratch_copy "$PAGE" "index-missing-path.md")"
  printf '\nRead `%sghost.md` now, the whole file.\n' "$SETUP_REFERENCES_PATH" >>"$copy"
  run check_reference_index "$copy" "$REFERENCES_DIRECTORY"
  [ "$status" -ne 0 ]
  grep -qF 'names a missing reference' <<<"$output"
}

@test "the reference index check fails when the references block drops a bullet" {
  local copy
  copy="$(scratch_copy "$PAGE" "index-dropped-bullet.md")"
  grep -v -- '^- `sandbox.md`: ' "$PAGE" >"$copy" || true
  cmp -s "$PAGE" "$copy" && return 1
  run check_reference_index "$copy" "$REFERENCES_DIRECTORY"
  [ "$status" -ne 0 ]
  grep -qF 'references block differs' <<<"$output"
}

@test "the reference index check fails when the entry has no Read line for a reference" {
  local copy
  copy="$(scratch_copy "$PAGE" "index-no-read-line.md")"
  sed "s#Read \`${SETUP_REFERENCES_PATH}squash-only.md\` now#Open \`${SETUP_REFERENCES_PATH}squash-only.md\`#" "$PAGE" >"$copy"
  cmp -s "$PAGE" "$copy" && return 1
  run check_reference_index "$copy" "$REFERENCES_DIRECTORY"
  [ "$status" -ne 0 ]
  grep -qF 'no Read line for squash-only.md' <<<"$output"
}

@test "the reference index check fails loudly when the opening sentence is reworded" {
  local copy
  copy="$(scratch_copy "$PAGE" "index-reworded.md")"
  sed 's/^This command reads these references/This command loads these references/' "$PAGE" >"$copy"
  cmp -s "$PAGE" "$copy" && return 1
  run check_reference_index "$copy" "$REFERENCES_DIRECTORY"
  [ "$status" -ne 0 ]
  grep -qF 'opening sentence is absent' <<<"$output"
}

# ---------------------------------------------------------------------------
# References stay one level deep
# ---------------------------------------------------------------------------

# check_one_level_deep <directory>: no reference names a references/setup path
# or carries a "Read ... references/" routing line. Routing lives only in the
# entry command.
check_one_level_deep() {
  local directory="$1" file count=0
  for file in "${directory}"/*.md; do
    [ -f "$file" ] || continue
    count=$((count + 1))
    if grep -qF -- 'references/setup/' "$file"; then
      echo "a reference names a references/setup path: ${file}" >&2
      return 1
    fi
    if grep -qE 'Read .*references/' "$file"; then
      echo "a reference carries a routing line to another reference: ${file}" >&2
      return 1
    fi
  done
  [ "$count" -gt 0 ] || {
    echo "no reference found in ${directory}" >&2
    return 1
  }
}

@test "no setup reference routes to another reference" {
  check_one_level_deep "$REFERENCES_DIRECTORY"
}

@test "the one-level check fails on a routing line to a sibling setup reference" {
  local directory
  directory="$(scratch_references deep-sibling)"
  printf '\nRead `%ssandbox.md` now.\n' "$SETUP_REFERENCES_PATH" >>"${directory}/per-machine.md"
  run check_one_level_deep "$directory"
  [ "$status" -ne 0 ]
}

@test "the one-level check fails on a routing line to a reference outside the setup folder" {
  local directory
  directory="$(scratch_references deep-outside)"
  printf '\nRead `.claude/skills/gaia/references/debt.md` now.\n' >>"${directory}/squash-only.md"
  run check_one_level_deep "$directory"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Line cap
# ---------------------------------------------------------------------------

# check_line_cap <newline-separated file list>: every file is at most 499
# lines, under the 500-line playbook cap.
check_line_cap() {
  local file lines count=0
  while IFS= read -r file; do
    count=$((count + 1))
    lines="$(wc -l <"$file" | tr -d ' ')"
    [ "$lines" -le 499 ] || {
      echo "${file} is ${lines} lines, over the cap" >&2
      return 1
    }
  done <<<"$1"
  [ "$count" -gt 0 ] || {
    echo "no file to check" >&2
    return 1
  }
}

# pad_to_lines <file> <total>: append blank lines until the file has <total>.
pad_to_lines() {
  local current
  current="$(wc -l <"$1" | tr -d ' ')"
  awk -v n="$(($2 - current))" 'BEGIN { for (i = 0; i < n; i++) print "" }' >>"$1"
}

@test "both commands and every setup reference are under the line cap" {
  local list
  list="$(surface_files "$PAGE" "$REFERENCES_DIRECTORY")"
  list="${list}"$'\n'"${INIT_PAGE}"
  check_line_cap "$list"
}

@test "the line cap check fails on a file padded to the cap and passes one line under" {
  local copy
  copy="$(scratch_copy "$PAGE" "cap-under.md")"
  pad_to_lines "$copy" 499
  run check_line_cap "$copy"
  [ "$status" -eq 0 ]
  copy="$(scratch_copy "$PAGE" "cap-over.md")"
  pad_to_lines "$copy" 500
  run check_line_cap "$copy"
  [ "$status" -ne 0 ]
}

@test "the line cap check fails on an over-cap reference in the surface list" {
  local directory list
  directory="$(scratch_references cap-reference)"
  pad_to_lines "${directory}/squash-only.md" 500
  list="$(surface_files "$PAGE" "$directory")"
  run check_line_cap "$list"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Contents line
# ---------------------------------------------------------------------------

# The frozen Contents form: one line starting `Contents: `, whose entries are
# the file's `## ` headings in file order, separated by `; ` and ended with a
# period. Each entry is the heading text after `## ` up to but not including
# its first ` (`, or the whole text when there is none. A `## ` line inside a
# fenced code block is not a heading and is skipped; a fence of N backticks
# closes only on a line of at least N backticks and nothing else.

# contents_headings <file>: the entries the headings call for, one per line.
contents_headings() {
  awk '
    match($0, /^`+/) && RLENGTH >= 3 {
      if (!fence) { fence = RLENGTH; next }
      if (RLENGTH >= fence && $0 ~ /^`+[[:space:]]*$/) { fence = 0 }
      next
    }
    !fence && /^## / {
      heading = substr($0, 4)
      cut = index(heading, " (")
      if (cut > 0) heading = substr(heading, 1, cut - 1)
      print heading
    }
  ' "$1"
}

# check_contents_line <file> <always|when-long>: the Contents line is exactly
# one and in the frozen form. "always" demands it; "when-long" demands it only
# above 100 lines, and validates any line a shorter file carries.
check_contents_line() {
  local file="$1" mode="$2" lines count line text entries headings
  lines="$(wc -l <"$file" | tr -d ' ')"
  count="$(grep -c '^Contents: ' "$file" || true)"
  if [ "$mode" = always ] || [ "$lines" -gt 100 ]; then
    [ "$count" -eq 1 ] || {
      echo "expected exactly one Contents line in ${file}, found ${count}" >&2
      return 1
    }
  fi
  [ "$count" -le 1 ] || {
    echo "more than one Contents line in ${file}" >&2
    return 1
  }
  [ "$count" -eq 1 ] || return 0
  line="$(grep '^Contents: ' "$file")"
  text="${line#Contents: }"
  case "$text" in
    *.) ;;
    *)
      echo "the Contents line of ${file} does not end with a period" >&2
      return 1
      ;;
  esac
  text="${text%.}"
  entries="$(CONTENTS_TEXT="$text" awk 'BEGIN { n = split(ENVIRON["CONTENTS_TEXT"], parts, "; "); for (i = 1; i <= n; i++) print parts[i] }')"
  headings="$(contents_headings "$file")"
  [ -n "$headings" ] || {
    echo "${file} has a Contents line and no headings" >&2
    return 1
  }
  [ "$entries" = "$headings" ] || {
    echo "the Contents line of ${file} differs from its headings:" >&2
    diff <(printf '%s\n' "$entries") <(printf '%s\n' "$headings") >&2 || true
    return 1
  }
}

# check_contents_over_surface <entry> <init> <directory>: both commands always,
# each reference when long.
check_contents_over_surface() {
  local entry="$1" init="$2" directory="$3" name
  check_contents_line "$entry" always || return 1
  check_contents_line "$init" always || return 1
  for name in $EXPECTED_SETUP_REFERENCES; do
    check_contents_line "${directory}/${name}" when-long || return 1
  done
}

@test "both commands and every long setup reference carry a Contents line in the frozen form" {
  check_contents_over_surface "$PAGE" "$INIT_PAGE" "$REFERENCES_DIRECTORY"
}

@test "the Contents check fails when the line is deleted from a command" {
  local copy
  copy="$(scratch_copy "$PAGE" "contents-deleted.md")"
  grep -v '^Contents: ' "$PAGE" >"$copy" || true
  cmp -s "$PAGE" "$copy" && return 1
  run check_contents_line "$copy" always
  [ "$status" -ne 0 ]
}

@test "the Contents check fails on a heading the line does not list" {
  local copy
  copy="$(scratch_copy "$PAGE" "contents-unlisted.md")"
  printf '\n## Phase 9: Unlisted\n' >>"$copy"
  run check_contents_line "$copy" always
  [ "$status" -ne 0 ]
  grep -qF 'differs from its headings' <<<"$output"
}

@test "the Contents check fails when an entry carries the heading's parenthetical" {
  local copy
  copy="$(scratch_copy "$PAGE" "contents-parenthetical.md")"
  sed 's/Phase 2: Per-machine setup;/Phase 2: Per-machine setup (skip if setup-state finalized);/' "$PAGE" >"$copy"
  cmp -s "$PAGE" "$copy" && return 1
  run check_contents_line "$copy" always
  [ "$status" -ne 0 ]
  grep -qF 'differs from its headings' <<<"$output"
}

@test "the Contents check fails when a long reference has no line" {
  local directory
  directory="$(scratch_references contents-long-reference)"
  pad_to_lines "${directory}/squash-only.md" 101
  run check_contents_over_surface "$PAGE" "$INIT_PAGE" "$directory"
  [ "$status" -ne 0 ]
  grep -qF 'expected exactly one Contents line' <<<"$output"
}

@test "the Contents check skips a heading inside a fence, including one nested in a longer fence" {
  local fixture="${BATS_TEST_TMPDIR}/contents-fenced.md" fence3='```' fence4='````'
  {
    printf '# Title\n\nContents: One; Two.\n\n## One\n\n'
    printf '%smd\n## Hidden\n%s\n\n' "$fence3" "$fence3"
    printf '%smd\n%s\n## Also hidden\n%s\n%s\n\n' "$fence4" "$fence3" "$fence3" "$fence4"
    printf '## Two (note)\n'
  } >"$fixture"
  check_contents_line "$fixture" always
}

@test "the Contents check lists a heading that follows a fence" {
  local fixture="${BATS_TEST_TMPDIR}/contents-after-fence.md" fence3='```'
  {
    printf '# Title\n\nContents: One.\n\n## One\n\n'
    printf '%smd\n## Hidden\n%s\n\n## Visible\n' "$fence3" "$fence3"
  } >"$fixture"
  run check_contents_line "$fixture" always
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# One per-machine source
# ---------------------------------------------------------------------------

PER_MACHINE_PATH='.claude/skills/gaia/references/setup/per-machine.md'

# per_machine_literals: one fixed string per line; each is the install command
# of a per-machine component and lives in the per-machine reference or the
# React Doctor installer script.
per_machine_literals() {
  printf '%s\n' \
    'react-doctor@latest install' \
    'oraios/serena@' \
    'claude plugin install claude-obsidian@' \
    'chmod +x .gaia/statusline'
}

# check_per_machine_source <per-machine-reference> <installer> <command>...:
# each literal appears in the reference or the installer and in no command,
# and every command names the per-machine reference path.
check_per_machine_source() {
  local per_machine="$1" installer="$2" literal command_file count=0
  shift 2
  [ -f "$installer" ] || {
    echo "the React Doctor installer is absent: ${installer}" >&2
    return 1
  }
  while IFS= read -r literal; do
    count=$((count + 1))
    grep -qF -- "$literal" "$per_machine" "$installer" || {
      echo "the per-machine source lacks: ${literal}" >&2
      return 1
    }
    for command_file in "$@"; do
      if grep -qF -- "$literal" "$command_file"; then
        echo "${command_file} carries a per-machine literal: ${literal}" >&2
        return 1
      fi
    done
  done < <(per_machine_literals)
  [ "$count" -gt 0 ] || return 1
  for command_file in "$@"; do
    grep -qF -- "$PER_MACHINE_PATH" "$command_file" || {
      echo "${command_file} does not name ${PER_MACHINE_PATH}" >&2
      return 1
    }
  done
}

@test "the install literals live only in the per-machine reference or the installer script" {
  check_per_machine_source "$PER_MACHINE_REFERENCE" "$REACT_DOCTOR_INSTALLER" "$PAGE" "$INIT_PAGE"
}

@test "the per-machine source check fails on each literal put back in either command" {
  local literal source_file copy count=0
  for source_file in "$PAGE" "$INIT_PAGE"; do
    while IFS= read -r literal; do
      count=$((count + 1))
      copy="$(scratch_copy "$source_file" "per-machine-literal-${count}.md")"
      printf '\n%s\n' "$literal" >>"$copy"
      if [ "$source_file" = "$PAGE" ]; then
        run check_per_machine_source "$PER_MACHINE_REFERENCE" "$REACT_DOCTOR_INSTALLER" "$copy" "$INIT_PAGE"
      else
        run check_per_machine_source "$PER_MACHINE_REFERENCE" "$REACT_DOCTOR_INSTALLER" "$PAGE" "$copy"
      fi
      [ "$status" -ne 0 ] || {
        echo "the check passed with ${literal} in ${source_file}" >&2
        return 1
      }
    done < <(per_machine_literals)
  done
  [ "$count" -gt 0 ]
}

@test "the per-machine source check fails when a command drops the per-machine path" {
  local source_file copy count=0
  for source_file in "$PAGE" "$INIT_PAGE"; do
    count=$((count + 1))
    copy="$(scratch_copy "$source_file" "per-machine-path-${count}.md")"
    sed "s#${PER_MACHINE_PATH}#.claude/skills/gaia/references/setup/gone.md#g" "$source_file" >"$copy"
    cmp -s "$source_file" "$copy" && return 1
    if [ "$source_file" = "$PAGE" ]; then
      run check_per_machine_source "$PER_MACHINE_REFERENCE" "$REACT_DOCTOR_INSTALLER" "$copy" "$INIT_PAGE"
    else
      run check_per_machine_source "$PER_MACHINE_REFERENCE" "$REACT_DOCTOR_INSTALLER" "$PAGE" "$copy"
    fi
    [ "$status" -ne 0 ]
    grep -qF 'does not name' <<<"$output"
  done
}

@test "the per-machine source check fails when a literal leaves the source" {
  local copy
  copy="$(scratch_copy "$PER_MACHINE_REFERENCE" "per-machine-no-serena.md")"
  grep -vF -- 'oraios/serena@' "$PER_MACHINE_REFERENCE" >"$copy" || true
  cmp -s "$PER_MACHINE_REFERENCE" "$copy" && return 1
  run check_per_machine_source "$copy" "$REACT_DOCTOR_INSTALLER" "$PAGE" "$INIT_PAGE"
  [ "$status" -ne 0 ]
  grep -qF 'lacks' <<<"$output"
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
