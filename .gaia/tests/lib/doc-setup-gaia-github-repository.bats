#!/usr/bin/env bats
# The Phase 3 GitHub repository fences of `.claude/commands/setup-gaia.md`,
# extracted and run against a stubbed `gh`. The `GAIA-Audit` registration
# fence adds `GAIA-Audit`, keeps every sibling context, drops the stale
# `code-review-audit` context, and sends no PUT when nothing is owed or the GET
# fails. The default-branch protection fence sends its full PUT only when no
# rule exists. Each fence exists exactly once across the setup surface (the
# command followed by every reference under
# `.claude/skills/gaia/references/setup/`), and that one copy sits in the
# command.
#
# Mutation tests prove each fixture fails on a fence with its guard removed.
#
# Assertion style: .claude/rules/bats-assertions.md.

# Each reference basename is named literally in this list: the change selector
# picks a suite only when it contains a changed file's basename, and this suite
# reads every reference through surface_files.
EXPECTED_SETUP_REFERENCES="per-machine.md sandbox.md github-repo.md isolation-question.md squash-only.md statusline-left.md setup-decisions.md standalone-features.md land-decisions.md sandbox-recommendation.md"

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/.claude/commands/setup-gaia.md"
  REFERENCES_DIRECTORY="${REPO_ROOT}/.claude/skills/gaia/references/setup"
  [ -f "$PAGE" ] || {
    echo "the audited page is absent: ${PAGE}" >&2
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
# fence must send it only when the probe finds no rule.

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
