#!/usr/bin/env bats
# Tests for `.gaia/scripts/debt-count-refresh.sh`, focused on the openCount
# exclusion filter (in-progress, debt:spec-pending, debt:spec-active).
#
# The script writes under `$PROJECT_ROOT/.gaia/local/debt/`, where PROJECT_ROOT
# derives from the script's own path. Each test runs a COPY inside an isolated
# sandbox so it never touches the real repo cache, with a stub `gh` on PATH.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SOURCE_SCRIPT="$THIS_DIRECTORY/../debt-count-refresh.sh"
  [ -f "$SOURCE_SCRIPT" ] || skip "debt-count-refresh.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq required"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia/scripts" "$SANDBOX/.gaia/local/debt" "$SANDBOX/bin"
  cp "$SOURCE_SCRIPT" "$SANDBOX/.gaia/scripts/debt-count-refresh.sh"
  chmod +x "$SANDBOX/.gaia/scripts/debt-count-refresh.sh"
  SCRIPT="$SANDBOX/.gaia/scripts/debt-count-refresh.sh"
  DEBT_DIRECTORY="$SANDBOX/.gaia/local/debt"
  SENTINEL="$DEBT_DIRECTORY/refresh-requested"
  CACHE="$DEBT_DIRECTORY/count.json"
}

# write_gh_stub <json> [extra-line]: a fake `gh` that serves <json> from
# `issue list` the way the real one does, which is what lets one stub cover both
# call shapes the refresher uses. Real `gh` applies a `--jq` filter when given
# one and emits the raw `--json` array when not, so the stub scans argv for
# `--jq` and does the same. A stub that answered only one shape would go green
# or red on the shape rather than on the behaviour under test.
# The fixture goes to a sidecar file rather than being spliced into the stub
# between single quotes: one apostrophe in an issue body would otherwise close
# the quote and emit a stub that is a syntax error, which presents as an empty
# read (a gh failure) and reds a test on a stale count instead of on the real
# cause.
write_gh_stub() {
  printf '%s' "$1" > "$SANDBOX/issues.json"
  cat > "$SANDBOX/bin/gh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  $2
  filter=""
  previous_argument=""
  for argument in "\$@"; do
    if [ "\$previous_argument" = "--jq" ]; then filter="\$argument"; fi
    previous_argument="\$argument"
  done
  if [ -n "\$filter" ]; then
    jq -r "\$filter" "$SANDBOX/issues.json"
  else
    cat "$SANDBOX/issues.json"
  fi
fi
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# stub_gh_json <json>: a fake `gh` serving a hand-written issue array, so the
# real exclusion expression runs against real labels rather than a pre-baked
# count.
stub_gh_json() {
  write_gh_stub "$1"
}

# Prepend the stub dir so our `gh` wins over any host `gh`; keep the rest of PATH
# so the real `jq` still resolves.
run_refresh() {
  ( cd "$SANDBOX" && PATH="$SANDBOX/bin:$PATH" "$SCRIPT" )
}

open_count() { jq -r '.openCount' "$CACHE"; }

# --- openCount exclusions --------------------------------------------------
# An open tech-debt issue carrying in-progress, debt:spec-pending or
# debt:spec-active is parked out of the backlog and must not inflate the nudge
# count.
#
# The first case's issue 1 carries an apostrophe in its body on purpose. Filed
# issue bodies routinely do, and it pins the stub's fixture handling: spliced
# into the stub between single quotes it would close the quote, make the stub a
# syntax error, and read as a gh failure that reds on a stale count rather than
# on the real cause.
@test "openCount excludes issues carrying in-progress, debt:spec-pending or debt:spec-active, each alone and together" {
  local label expected issues
  while IFS='|' read -r label expected issues; do
    stub_gh_json "$issues"
    : > "$SENTINEL"
    run run_refresh
    if [ "$status" -ne 0 ] || [ "$(open_count)" != "$expected" ]; then
      echo "case '$label': status=$status openCount=$(open_count 2>/dev/null) expected=$expected" >&2
      return 1
    fi
  done <<'ROWS'
in-progress|2|[{"number":1,"labels":[{"name":"tech-debt"},{"name":"severity:major"}],"body":"the refresher's own count"},{"number":2,"labels":[{"name":"tech-debt"},{"name":"severity:minor"},{"name":"in-progress"}]},{"number":3,"labels":[{"name":"tech-debt"},{"name":"severity:critical"}]}]
debt:spec-pending|2|[{"number":1,"labels":[{"name":"tech-debt"},{"name":"severity:major"}]},{"number":2,"labels":[{"name":"tech-debt"},{"name":"severity:minor"},{"name":"debt:spec-pending"}]},{"number":3,"labels":[{"name":"tech-debt"},{"name":"severity:critical"}]}]
debt:spec-active|2|[{"number":1,"labels":[{"name":"tech-debt"},{"name":"severity:major"}]},{"number":2,"labels":[{"name":"tech-debt"},{"name":"severity:minor"},{"name":"debt:spec-active"}]},{"number":3,"labels":[{"name":"tech-debt"},{"name":"severity:critical"}]}]
every label together|1|[{"number":1,"labels":[{"name":"tech-debt"}]},{"number":2,"labels":[{"name":"tech-debt"},{"name":"in-progress"}]},{"number":3,"labels":[{"name":"tech-debt"},{"name":"debt:spec-pending"}]},{"number":4,"labels":[{"name":"tech-debt"},{"name":"debt:spec-active"}]},{"number":5,"labels":[{"name":"tech-debt"},{"name":"in-progress"},{"name":"debt:spec-pending"},{"name":"debt:spec-active"}]}]
ROWS
}
