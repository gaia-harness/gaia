#!/usr/bin/env bash
# 12-debt-source-stripped.sh
#
# Proves a release-built tree files tech-debt issues with no source record:
#   1. The staged file-tech-debt.sh holds none of the source-line code.
#   2. No staged markdown file carries the source-line marker.
#   3. The staged file-tech-debt.sh still parses.
#   4. No debt-source-*.sh file reaches the staging tree.
#   5. A filing run from the staged script writes a body whose line 1 is the
#      dedup key and whose line 2 is empty, as it did before the record
#      existed.
#
# The filing runs with a fresh scratch git repository as its working
# directory, never a git-initialized staging tree: main-root-lib.sh resolves
# the working root from the process's working directory, so a scratch repo
# keeps the run off the real checkout and off the staging tree. A gh stub on
# PATH answers every read the script makes and records the body it is handed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_command git
require_command jq
require_command rsync

STAGING="$(mktemp -d -t gaia-dist-debt-source-XXXXXX)"
SCRATCH="$(mktemp -d -t gaia-dist-debt-source-run-XXXXXX)"
trap 'rm -rf "$STAGING" "$SCRATCH"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

STAGED_SCRIPT="$STAGING/.gaia/scripts/file-tech-debt.sh"

# 1. The staged script holds none of the source-line code.
[ -f "$STAGED_SCRIPT" ] || { fail "staged file-tech-debt.sh missing"; exit 1; }
for needle in 'gaia-debt-source' 'source_branch' '--source-branch' 'debt-source'; do
  if grep -qF -- "$needle" "$STAGED_SCRIPT"; then
    fail "staged file-tech-debt.sh leaked source-line code: $needle"
    exit 1
  fi
done

# 2. No staged markdown file carries the source-line marker.
LEAKED_DOCS="$(grep -rlF --include='*.md' -- 'gaia-debt-source' "$STAGING" 2>/dev/null || true)"
if [ -n "$LEAKED_DOCS" ]; then
  printf '%s\n' "$LEAKED_DOCS" >&2
  fail "staged markdown leaked the source-line marker"
  exit 1
fi

# 3. The staged script parses.
/bin/bash -n "$STAGED_SCRIPT" \
  || { fail "staged file-tech-debt.sh does not parse"; exit 1; }

# 4. The library, the report and any sibling are absent.
LEAKED_SCRIPTS="$(find "$STAGING/.gaia/scripts" -maxdepth 1 -name 'debt-source-*.sh' 2>/dev/null || true)"
if [ -n "$LEAKED_SCRIPTS" ]; then
  printf '%s\n' "$LEAKED_SCRIPTS" >&2
  fail "debt-source script reached the staging tree"
  exit 1
fi

# 5. Filing from the staged script.
STUB="$SCRATCH/stub"
BIN="$SCRATCH/bin"
WORK="$SCRATCH/work"
mkdir -p "$STUB" "$BIN" "$WORK"
git init -q "$WORK"

cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"--json nameWithOwner"*) echo owner/name ;;
  *"--json visibility"*) echo PUBLIC ;;
  *"--json hasIssuesEnabled"*) echo '{"hasIssuesEnabled":true,"viewerPermission":"ADMIN"}' ;;
  "issue list"*"--limit 1 "*) echo '[]' ;;
  "issue list"*"--label severity:investigate"*) echo '[]' ;;
  "issue list"*"--state open"*) echo '[]' ;;
  "issue list"*"--state closed"*) echo '[]' ;;
  "issue create"*)
    body_file="$(printf '%s\n' "$@" | sed -n '/^--body-file$/{n;p;}')"
    cp "$body_file" "$STUB_DIR/body"
    echo "https://github.com/owner/name/issues/101"
    ;;
  "issue view"*)
    [ -f "$STUB_DIR/body" ] && jq -n -c --rawfile body "$STUB_DIR/body" '{body: $body}'
    ;;
  "label list"*) printf 'tech-debt\nseverity:major\nseverity:minor\nseverity:critical\naudience:adopter\n' ;;
  *) ;;
esac
exit 0
STUB
chmod +x "$BIN/gh"

jq -n -c '{member: "code-audit-frontend", finding_class: "holistic/swallowed-error",
  path: "app/a.ts", line: 10, severity: "minor", security: false,
  title: "Swallowed error in loader", failure_mode: "The catch drops the error.",
  suggested_fix: "Rethrow it."}' >"$SCRATCH/finding.json"

FILED_OUTPUT="$(cd "$WORK" && STUB_DIR="$STUB" PATH="$BIN:$PATH" bash "$STAGED_SCRIPT" file \
  --finding "$SCRATCH/finding.json" --outcome-file "$SCRATCH/outcomes.jsonl" \
  --repo owner/name 2>"$SCRATCH/stderr")" || {
  cat "$SCRATCH/stderr" >&2
  fail "staged filing run exited non-zero"
  exit 1
}
if [ "$FILED_OUTPUT" != "filed 101" ]; then
  cat "$SCRATCH/stderr" >&2
  fail "staged filing run answered '$FILED_OUTPUT', expected 'filed 101'"
  exit 1
fi
[ -f "$STUB/body" ] || { fail "staged filing run recorded no issue body"; exit 1; }
LINE_ONE="$(sed -n '1p' "$STUB/body")"
case "$LINE_ONE" in
  '<!-- gaia-debt-key: v1 '*) ;;
  *) fail "body line 1 is not the dedup key: $LINE_ONE"; exit 1 ;;
esac
LINE_TWO="$(sed -n '2p' "$STUB/body")"
if [ -n "$LINE_TWO" ]; then
  fail "body line 2 is not empty: $LINE_TWO"
  exit 1
fi

pass "release tree files with no source record: script stripped, library and report absent"
