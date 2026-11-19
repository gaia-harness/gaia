#!/usr/bin/env bats

# The claim fields check-updates.sh writes into the update-check cache
# (gaiaOriginVersion, gaiaUpdateClaims, ghLogin), driven through a stub `gh`
# that answers from fixture files. The claim logic itself lives in
# update-claim.sh; this suite pins the wiring and the fallbacks.
#
# Run via: bash .gaia/scripts/bats5.sh .gaia/scripts/tests/check-updates-claims.bats < /dev/null

setup() {
  SCRIPTS_DIRECTORY="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v jq >/dev/null 2>&1 || skip "jq required"

  REFRESH_ROOT="$(mktemp -d "$BATS_TEST_TMPDIR/root.XXXXXX")"
  REFRESH_ROOT="$(cd "$REFRESH_ROOT" && pwd -P)"
  mkdir -p "$REFRESH_ROOT/.gaia/scripts" "$REFRESH_ROOT/.gaia/cli" "$REFRESH_ROOT/.gaia/local/cache/shared" "$BATS_TEST_TMPDIR/bin"
  cp "$SCRIPTS_DIRECTORY/check-updates.sh" "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  cp "$SCRIPTS_DIRECTORY/exclusive-lock-lib.sh" "$REFRESH_ROOT/.gaia/scripts/exclusive-lock-lib.sh"
  cp "$SCRIPTS_DIRECTORY/update-claim.sh" "$REFRESH_ROOT/.gaia/scripts/update-claim.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$REFRESH_ROOT/.gaia/cli/gaia"
  chmod +x "$REFRESH_ROOT/.gaia/cli/gaia"

  GH_STATE="$BATS_TEST_TMPDIR/gh-state"
  mkdir -p "$GH_STATE"
  export GH_STATE
  export REAL_JQ
  REAL_JQ="$(command -v jq)"
  printf '[]' >"$GH_STATE/pr-list.json"
  printf 'octo-cat\n' >"$GH_STATE/login.txt"
  printf '2.0.4\n' >"$GH_STATE/origin-version.txt"
  write_stub_gh "$BATS_TEST_TMPDIR/bin/gh"

  CACHE_FILE="$REFRESH_ROOT/.gaia/local/cache/shared/update-check.json"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

write_stub_gh() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
state="$GH_STATE"
case "$1 $2" in
  "release list") printf 'v0.0.0\n'; exit 0 ;;
  "pr list")
    [ -e "$state/fail-list" ] && exit 1
    cat "$state/pr-list.json"
    exit 0 ;;
esac
if [ "$1" = "api" ]; then
  case "$*" in
    *"contents/.gaia/VERSION"*)
      [ -e "$state/fail-origin" ] && exit 1
      cat "$state/origin-version.txt"
      exit 0 ;;
    *"user"*)
      [ -e "$state/fail-login" ] && exit 1
      cat "$state/login.txt"
      exit 0 ;;
  esac
fi
exit 1
EOF
  chmod +x "$1"
}

run_refresher() {
  run bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh" </dev/null
  [ "$status" -eq 0 ]
  [ -s "$CACHE_FILE" ]
}

claim_payload() {
  # claim_payload <number> <head> <login>
  jq -n --argjson number "$1" --arg head "$2" --arg login "$3" \
    '[{number: $number, headRefName: $head, author: {login: $login}, createdAt: "2026-10-18T12:00:00Z", isCrossRepository: false}]'
}

@test "a refresh writes the origin version, the live claims and the login" {
  claim_payload 41 "update/v2.0.4-2026-10-18-1200" other >"$GH_STATE/pr-list.json"
  run_refresher
  [ "$(jq -r '.gaiaOriginVersion' "$CACHE_FILE")" = "2.0.4" ]
  [ "$(jq -r '.ghLogin' "$CACHE_FILE")" = "octo-cat" ]
  [ "$(jq -c '.gaiaUpdateClaims' "$CACHE_FILE")" = '[{"number":41,"headRefName":"update/v2.0.4-2026-10-18-1200","tag":"v2.0.4","authorLogin":"other","createdAt":"2026-10-18T12:00:00Z"}]' ]
}

# reset_case: a clean cache, no failing verbs and the claim script back in place,
# so each row of a case table starts from the setup state.
reset_case() {
  rm -f "$CACHE_FILE" "$GH_STATE"/fail-*
  cp "$SCRIPTS_DIRECTORY/update-claim.sh" "$REFRESH_ROOT/.gaia/scripts/update-claim.sh"
  printf '[]' >"$GH_STATE/pr-list.json"
  printf 'octo-cat\n' >"$GH_STATE/login.txt"
}

@test "failed or missing reads fall back to empty or previous values" {
  echo "case: a failing claim list writes an empty claims array and keeps the other fields"
  reset_case
  : >"$GH_STATE/fail-list"
  run_refresher
  [ "$(jq -c '.gaiaUpdateClaims' "$CACHE_FILE")" = "[]" ]
  [ "$(jq -r '.gaiaOriginVersion' "$CACHE_FILE")" = "2.0.4" ]
  [ "$(jq -r '.ghLogin' "$CACHE_FILE")" = "octo-cat" ]

  echo "case: a failing origin read keeps the previous cached origin version"
  reset_case
  jq -n '{checkedAt: 0, gaiaOriginVersion: "2.0.1"}' >"$CACHE_FILE"
  : >"$GH_STATE/fail-origin"
  run_refresher
  [ "$(jq -r '.gaiaOriginVersion' "$CACHE_FILE")" = "2.0.1" ]

  echo "case: a failing origin read with no previous value leaves the origin version empty"
  reset_case
  : >"$GH_STATE/fail-origin"
  run_refresher
  [ -z "$(jq -r '.gaiaOriginVersion // ""' "$CACHE_FILE")" ]

  echo "case: a failing login read writes an empty ghLogin"
  reset_case
  : >"$GH_STATE/fail-login"
  run_refresher
  [ "$(jq -r '.ghLogin' "$CACHE_FILE")" = "" ]

  echo "case: a refresh with no claim script still writes the cache with empty claim fields"
  reset_case
  rm "$REFRESH_ROOT/.gaia/scripts/update-claim.sh"
  run_refresher
  [ "$(jq -c '.gaiaUpdateClaims' "$CACHE_FILE")" = "[]" ]
  [ "$(jq -r '.ghLogin' "$CACHE_FILE")" = "" ]
}

@test "a login or claim with control bytes never reaches the cache" {
  echo "case: an out-of-set login writes an empty ghLogin"
  reset_case
  printf 'bad\033name\n' >"$GH_STATE/login.txt"
  run_refresher
  [ "$(jq -r '.ghLogin' "$CACHE_FILE")" = "" ]

  echo "case: a claim with a control byte never reaches the cache file"
  reset_case
  claim_payload 41 "update/v2.0.4-2026-10-18-1200" "$(printf 'bad\033name')" >"$GH_STATE/pr-list.json"
  run_refresher
  [ "$(jq -c '.gaiaUpdateClaims' "$CACHE_FILE")" = "[]" ]
  LC_ALL=C grep -q "$(printf '[\001-\011\013-\037]')" "$CACHE_FILE" && return 1
  true
}
