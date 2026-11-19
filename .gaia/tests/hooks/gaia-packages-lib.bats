#!/usr/bin/env bats
# Conformance suite for .claude/hooks/lib/gaia-packages.sh, the bash reader of
# the package registry (.gaia/packages.json) and per-package descriptors
# (<path>/gaia.package.json), SPEC-092 contract C1 to C4.
#
# One of two implementations of one contract. The TypeScript twin
# (.gaia/cli/src/util/packages.ts) is driven over the SAME corpus by
# .gaia/cli/src/util/packages.test.ts, so a corpus edit that one implementation
# disagrees with fails there. This file is the bash half. It lives in a seam directory so the bats sharder runs it (S13).
#
# Corpus layout, .gaia/tests/fixtures/gaia-packages/<case>/: an optional
# packages.json (installed as .gaia/packages.json), optional descriptor files at
# their package paths, and expected.json. Assertion style:
# .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  LIBRARY="$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh"
  CORPUS="$REPO_ROOT/.gaia/tests/fixtures/gaia-packages"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
  [ -f "$LIBRARY" ]
  command -v jq >/dev/null 2>&1 || skip "jq required"
}

# materialize <corpus-case-dir> <repo-root>: copy the case into a fresh repo
# root, installing packages.json as .gaia/packages.json and dropping the oracle.
materialize() {
  mkdir -p "$2/.gaia"
  cp -R "$1/." "$2/"
  rm -f "$2/expected.json"
  if [ -f "$2/packages.json" ]; then
    mv "$2/packages.json" "$2/.gaia/packages.json"
  fi
}

# check_members <expected.json>: the web and settings answers, when the oracle states them.
check_members() {
  local expected="$1" want got name failures=0
  if [ "$(jq 'has("webMembers")' "$expected")" = true ]; then
    want=$(jq -r '.webMembers[]?' "$expected")
    got=$(gaia_packages_web_members | cut -f1)
    if [ "$got" != "$want" ]; then
      echo "webMembers: want [$want], got [$got]"
      failures=1
    fi
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      gaia_package_is_web "$name" || {
        echo "is_web [$name]: want 0"
        failures=1
      }
    done <<<"$want"
  fi
  if [ "$(jq 'has("settingsMembers")' "$expected")" = true ]; then
    want=$(jq -r '.settingsMembers[]?' "$expected")
    got=$(gaia_packages_list | cut -f1 | while IFS= read -r name; do
      if gaia_package_wants_settings "$name"; then printf '%s\n' "$name"; fi
    done)
    if [ "$got" != "$want" ]; then
      echo "settingsMembers: want [$want], got [$got]"
      failures=1
    fi
  fi
  return "$failures"
}

# check_case <expected.json> <repo-root>: print one line per disagreement with
# the oracle and return 1 when there is any. Runs the library in this shell.
check_case() {
  local expected="$1" root="$2" status=0 want_load want_error got failures=0
  local key candidate want_dir ere line field_a field_b
  local sep=$'\037'

  # A previous case's state must not survive: the library resets on every load.
  gaia_packages_load "$root" || status=$?
  want_load=$(jq -r '.load' "$expected")
  if [ "$status" != "$want_load" ]; then
    echo "load: want $want_load, got $status ($GAIA_PACKAGES_ERROR)"
    return 1
  fi
  if [ "$want_load" != 0 ]; then
    want_error=$(jq -r '.error' "$expected")
    if [ "$GAIA_PACKAGES_ERROR" != "$want_error" ]; then
      echo "error text: want [$want_error], got [$GAIA_PACKAGES_ERROR]"
      failures=1
    fi
    # A failed load must answer as if nothing were loaded.
    if [ -n "$(gaia_packages_list)" ] || [ -n "$(gaia_package_globs_ere tddUnitTests)" ]; then
      echo "failed load left state behind"
      failures=1
    fi
    [ "$failures" = 0 ]
    return
  fi

  got=$(gaia_packages_list)
  if [ "$got" != "$(jq -r '.list | map(join("\t")) | .[]' "$expected")" ]; then
    echo "list: got [$got]"
    failures=1
  fi

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    ere=$(gaia_package_globs_ere "$key")
    if [ "$(jq -r --arg k "$key" '.globs[$k].empty // false' "$expected")" = true ]; then
      if [ -n "$ere" ]; then
        echo "$key: want empty ERE, got [$ere]"
        failures=1
      fi
      continue
    fi
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      [[ $candidate =~ $ere ]] || {
        echo "$key: want match for [$candidate] under [$ere]"
        failures=1
      }
    done < <(jq -r --arg k "$key" '.globs[$k].match[]?' "$expected")
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      if [[ $candidate =~ $ere ]]; then
        echo "$key: want NO match for [$candidate] under [$ere]"
        failures=1
      fi
    done < <(jq -r --arg k "$key" '.globs[$k].noMatch[]?' "$expected")
  done < <(jq -r '.globs // {} | keys[]' "$expected")

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    field_a="${line%%"$sep"*}"
    field_b="${line#*"$sep"}"
    got=$(gaia_package_for_path "$field_a")
    if [ "$got" != "$field_b" ]; then
      echo "for_path [$field_a]: want [$field_b], got [$got]"
      failures=1
    fi
  done < <(jq -r '.forPath // {} | to_entries[] | .key + "\u001f" + .value' "$expected")

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    field_a="${line%%"$sep"*}"
    want_dir="${line#*"$sep"}"
    if got=$(gaia_package_dir "$field_a"); then
      [ "$got" = "$want_dir" ] || {
        echo "dir [$field_a]: want [$want_dir], got [$got]"
        failures=1
      }
    else
      [ "$want_dir" = "-null-" ] || {
        echo "dir [$field_a]: want [$want_dir], got unknown"
        failures=1
      }
    fi
  done < <(jq -r '.dir // {} | to_entries[] | .key + "\u001f" + (.value // "-null-")' "$expected")

  check_members "$expected" || failures=1

  [ "$failures" = 0 ]
}

@test "corpus: every case's expected answers hold for the bash reader" {
  # shellcheck source=/dev/null
  . "$LIBRARY"
  local case_directory case_name checked=0 failed=0 report
  for case_directory in "$CORPUS"/*/; do
    case_name="$(basename "$case_directory")"
    [ -f "$case_directory/expected.json" ] || {
      echo "case $case_name has no expected.json"
      failed=$((failed + 1))
      continue
    }
    materialize "$case_directory" "$BATS_TEST_TMPDIR/$case_name"
    if report=$(check_case "$case_directory/expected.json" "$BATS_TEST_TMPDIR/$case_name"); then
      :
    else
      echo "FAIL $case_name:"
      echo "$report"
      failed=$((failed + 1))
    fi
    checked=$((checked + 1))
  done
  # The floor keeps an emptied or mis-pathed corpus from passing vacuously.
  [ "$checked" -ge 35 ] || {
    echo "only $checked corpus cases found"
    return 1
  }
  [ "$failed" = 0 ]
}

@test "a descriptor that still carries a retired globs key loads clean and the key answers nothing" {
  # shellcheck source=/dev/null
  . "$LIBRARY"
  local retired_key status=0 key_status=0
  # The retired key is whatever the leftover fixture carries beyond a current descriptor.
  retired_key="$(comm -13 \
    <(jq -r '.globs | keys[]' "$CORPUS/path-frontend/frontend/gaia.package.json" | sort) \
    <(jq -r '.globs | keys[]' "$CORPUS/descriptor-leftover-selfheal-key/frontend/gaia.package.json" | sort))"
  [ -n "$retired_key" ]
  materialize "$CORPUS/descriptor-leftover-selfheal-key" "$BATS_TEST_TMPDIR/r"
  gaia_packages_load "$BATS_TEST_TMPDIR/r" || status=$?
  [ "$status" -eq 0 ]
  [ -z "$GAIA_PACKAGES_ERROR" ]
  [ -n "$(gaia_package_globs_ere tddUnitTests)" ]
  gaia_package_globs_ere "$retired_key" >/dev/null 2>&1 || key_status=$?
  [ "$key_status" -eq 1 ]
}

# Each row loads a good case, confirms it answered, then loads a bad case of
# a different failure kind; every answer must be cleared afterwards.
@test "a failed load after a good one clears the earlier answers, including the web answers" {
  # shellcheck source=/dev/null
  . "$LIBRARY"
  local row label good bad expected_status status
  for row in \
    "malformed-registry|path-frontend|registry-malformed-json|2" \
    "invalid-stack-descriptor|stack-web|descriptor-stack-invalid|3"; do
    IFS='|' read -r label good bad expected_status <<<"$row"
    materialize "$CORPUS/$good" "$BATS_TEST_TMPDIR/$label-good"
    materialize "$CORPUS/$bad" "$BATS_TEST_TMPDIR/$label-bad"
    gaia_packages_load "$BATS_TEST_TMPDIR/$label-good" || { echo "case $label: good load failed"; return 1; }
    case "$label" in
      malformed-registry) [ -n "$(gaia_package_globs_ere tddUnitTests)" ] || { echo "case $label: good load gave no globs"; return 1; } ;;
      invalid-stack-descriptor) [ -n "$(gaia_packages_web_members)" ] || { echo "case $label: good load gave no web members"; return 1; } ;;
    esac
    status=0
    gaia_packages_load "$BATS_TEST_TMPDIR/$label-bad" || status=$?
    [ "$status" -eq "$expected_status" ] || { echo "case $label: status=$status"; return 1; }
    [ -z "$(gaia_package_globs_ere tddUnitTests)" ] || { echo "case $label: globs survived"; return 1; }
    [ -z "$(gaia_packages_list)" ] || { echo "case $label: list survived"; return 1; }
    [ -z "$(gaia_packages_web_members)" ] || { echo "case $label: web members survived"; return 1; }
  done
}

@test "jq unavailable: load returns 4 naming jq, and an absent registry does not fall back to the built-in default" {
  local row label root shimmed_path
  shimmed_path="$(path_shim_without jq)"
  materialize "$CORPUS/path-frontend" "$BATS_TEST_TMPDIR/registry-present"
  mkdir -p "$BATS_TEST_TMPDIR/registry-absent"
  for label in registry-present registry-absent; do
    root="$BATS_TEST_TMPDIR/$label"
    PATH="$shimmed_path" run bash -c 'command -v jq && exit 99
      . "$1"; status=0; gaia_packages_load "$2" || status=$?
      printf "%s\n" "$status" "globs=$(gaia_package_globs_ere tddUnitTests)" "$GAIA_PACKAGES_ERROR"' _ "$LIBRARY" "$root"
    [ "$status" -eq 0 ] || { echo "case $label: shim leaked jq or the shell failed: $output"; return 1; }
    [ "${lines[0]}" = 4 ] || { echo "case $label: load=${lines[0]}"; return 1; }
    [ "${lines[1]}" = "globs=" ] || { echo "case $label: fell back to ${lines[1]}"; return 1; }
    [[ "${lines[2]}" == *jq* ]] || { echo "case $label: error does not name jq: ${lines[2]}"; return 1; }
    [[ "${lines[2]}" == *"Next step: "* ]] || { echo "case $label: error has no next step: ${lines[2]}"; return 1; }
  done
}

@test "registry absent: the committed descriptor drives the built-in default, apps/web/app matches and root app does not" {
  # shellcheck source=/dev/null
  . "$LIBRARY"
  mkdir -p "$BATS_TEST_TMPDIR/absent/apps/web"
  cp "$REPO_ROOT/apps/web/gaia.package.json" "$BATS_TEST_TMPDIR/absent/apps/web/"
  gaia_packages_load "$BATS_TEST_TMPDIR/absent"
  local ere
  ere="$(gaia_package_globs_ere tddUnitTests)"
  [[ "apps/web/app/utils/x.test.ts" =~ $ere ]]
  [[ "app/utils/x.test.ts" =~ $ere ]] && return 1
  true
}

@test "package globs: each glob joined to its package path in registry order, empty before a load, 1 on an unknown key" {
  # shellcheck source=/dev/null
  . "$LIBRARY"
  local status=0
  [ -z "$(gaia_package_globs tddStrictCandidates)" ]
  materialize "$CORPUS/two-packages" "$BATS_TEST_TMPDIR/r"
  gaia_packages_load "$BATS_TEST_TMPDIR/r"
  run gaia_package_globs tddStrictCandidates
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 12 ]
  [ "${lines[0]}" = 'frontend/app/utils/**' ]
  [ "${lines[4]}" = 'ios/app/utils/**' ]
  [ "${lines[11]}" = 'frontend/inner/app/components/**/*.ts' ]
  # A package at `.` contributes its globs unjoined.
  materialize "$CORPUS/path-dot" "$BATS_TEST_TMPDIR/dot"
  gaia_packages_load "$BATS_TEST_TMPDIR/dot"
  [ "$(gaia_package_globs tddUnitTests | head -1)" = 'app/**/*.test.ts' ]
  status=0
  gaia_package_globs notAKey >/dev/null 2>&1 || status=$?
  [ "$status" -eq 1 ]
}

# bats test_tags=whole-tree
@test "the committed descriptor loads clean through the committed registry" {
  # shellcheck source=/dev/null
  . "$LIBRARY"
  local status=0
  gaia_packages_load "$REPO_ROOT" || status=$?
  [ "$status" -eq 0 ]
}

# A hostile registry path is refused as malformed; a hostile descriptor glob is
# data and loads. Neither may run its embedded command.
@test "a hostile registry path or glob is data and runs nothing" {
  # shellcheck source=/dev/null
  . "$LIBRARY"
  local row label expected_status root marker status
  for row in "registry-path|2" "descriptor-glob|0"; do
    label=${row%%|*}; expected_status=${row#*|}
    root="$BATS_TEST_TMPDIR/hostile-$label" marker="$BATS_TEST_TMPDIR/pwned-$label"
    case "$label" in
      registry-path)
        mkdir -p "$root/.gaia"
        jq -n --arg p "frontend\"; touch $marker" '[{name: "frontend", path: $p}]' >"$root/.gaia/packages.json" ;;
      descriptor-glob)
        materialize "$CORPUS/path-frontend" "$root"
        jq --arg g "\$(touch $marker)" '.globs.doctorConfigs = [$g]' \
          "$root/frontend/gaia.package.json" >"$root/frontend/next.json"
        mv "$root/frontend/next.json" "$root/frontend/gaia.package.json" ;;
    esac
    status=0
    gaia_packages_load "$root" || status=$?
    [ "$status" -eq "$expected_status" ] || { echo "case $label: status=$status"; return 1; }
    [ -e "$marker" ] && { echo "case $label: embedded command ran"; return 1; }
  done
  true
}

@test "the library is safe under set -euo pipefail with unset caller state" {
  materialize "$CORPUS/path-frontend" "$BATS_TEST_TMPDIR/r"
  run bash -c 'set -euo pipefail; . "$1"; status=0; gaia_packages_load "$2" || status=$?
    [ "$status" -eq 0 ]; gaia_package_for_path frontend/app/x.ts; gaia_package_dir nope || true' _ "$LIBRARY" "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  [ "$output" = frontend ]
}

# Rows: the mixed registry (an all-empty lib beside a web member) and the same
# registry cut down to the all-empty lib alone.
@test "an all-empty member leaves no empty alternative and no web member" {
  # shellcheck source=/dev/null
  . "$LIBRARY"
  local label key ere status
  for label in mixed-registry single-member; do
    materialize "$CORPUS/non-web-all-empty" "$BATS_TEST_TMPDIR/$label"
    if [ "$label" = single-member ]; then
      rm -rf "$BATS_TEST_TMPDIR/$label/frontend"
      jq 'del(.[0])' "$BATS_TEST_TMPDIR/$label/.gaia/packages.json" >"$BATS_TEST_TMPDIR/next.json"
      mv "$BATS_TEST_TMPDIR/next.json" "$BATS_TEST_TMPDIR/$label/.gaia/packages.json"
    fi
    gaia_packages_load "$BATS_TEST_TMPDIR/$label" || { echo "case $label: load failed"; return 1; }
    case "$label" in
      mixed-registry)
        for key in tddUnitTests tddStrictCandidates emergentTests preCommitSource doctorConfigs dependencyManifests; do
          ere="$(gaia_package_globs_ere "$key")"
          [ -n "$ere" ] || { echo "case $label: $key ERE empty"; return 1; }
          [[ $ere == *"||"* ]] && { echo "case $label: $key has ||"; return 1; }
          [[ $ere == *"(|"* ]] && { echo "case $label: $key has (|"; return 1; }
          [[ $ere == *"|)"* ]] && { echo "case $label: $key has |)"; return 1; }
        done
        ere="$(gaia_package_globs_ere tddUnitTests)"
        [[ "packages/lib/src/a.test.ts" =~ $ere ]] && { echo "case $label: lib test matched"; return 1; }
        ;;
      single-member)
        [ -z "$(gaia_package_globs_ere tddUnitTests)" ] || { echo "case $label: tddUnitTests not empty"; return 1; }
        [ "$(gaia_package_globs_ere preCommitSource)" = '^(packages/lib/.*)$' ] || { echo "case $label: preCommitSource"; return 1; }
        [ -z "$(gaia_packages_web_members)" ] || { echo "case $label: has a web member"; return 1; }
        for key in lib nope; do
          status=0
          gaia_package_is_web "$key" || status=$?
          [ "$status" -eq 1 ] || { echo "case $label: is_web $key=$status"; return 1; }
        done
        ;;
    esac
  done
  true
}

@test "web members: exactly the web member of a mixed registry, tab-separated, registry order" {
  # shellcheck source=/dev/null
  . "$LIBRARY"
  materialize "$CORPUS/non-web-all-empty" "$BATS_TEST_TMPDIR/r"
  gaia_packages_load "$BATS_TEST_TMPDIR/r"
  [ "$(gaia_packages_web_members)" = "$(printf 'frontend\tfrontend')" ]
  gaia_package_wants_settings frontend
  run gaia_package_wants_settings lib
  [ "$status" -eq 1 ]
}
