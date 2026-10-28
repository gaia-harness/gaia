#!/usr/bin/env bash
# Helpers for the CSF4 migration scenario. Sourced after lib.sh and
# data-layer.sh, with HERE set to the distribution directory.
#
# API:
#   csf4_stage_tree              - stages and installs a release tree, commits it
#                                  as BASE_COMMIT; sets SCAFFOLD, FRONTEND, GAIA
#   csf4_reset_tree              - back to the pristine staged tree, clean
#   csf4_commit MESSAGE          - commits everything in the scaffold
#   csf4_drop_stories            - removes every story file the release ships
#   csf4_install_fixture DIR     - copies a fixture directory into frontend/,
#                                  dropping the .csf2/.csf3 suffix
#   csf4_use_config PREVIEW      - swaps in a CSF3 preview and main, and removes
#                                  the package.json imports entry
#   csf4_migrate [ARG...]        - runs the command with stdin closed and --json;
#                                  sets MIGRATE_EXIT, MIGRATE_JSON, MIGRATE_STDERR
#   csf4_field EXPRESSION        - evaluates an expression over `parsed`, the
#                                  last command's JSON object
#   csf4_expect LABEL EXIT       - fails unless the last command exited EXIT
#   csf4_fingerprint             - prints a hash of every non-ignored file and
#                                  the porcelain status
#   csf4_vitest_report OUT       - runs the storybook Vitest project into OUT

FIXTURES="$HERE/fixtures/csf4-migration"

csf4_git() {
  git -C "$SCAFFOLD" -c user.name=dist -c user.email=dist@example.com \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

csf4_stage_tree() {
  if [ -n "${GAIA_CSF4_REUSE_SCAFFOLD:-}" ]; then
    # Local iteration only: an already installed scaffold from a previous run.
    SCAFFOLD="$GAIA_CSF4_REUSE_SCAFFOLD"
    WORK="$(mktemp -d -t gaia-dist-csf4-work-XXXXXX)"
    trap 'rm -rf "$WORK"' EXIT
    capture_cli_stderr "$WORK/cli-stderr.txt"
    GAIA="$SCAFFOLD/.gaia/cli/gaia"
    FRONTEND="$SCAFFOLD/frontend"
    export GAIA_TELEMETRY_PING_DISABLE=1
    BASE_COMMIT="$(csf4_git rev-list --max-parents=0 HEAD)"
    GAIA="${GAIA_CSF4_BINARY:-$GAIA}"
    csf4_reset_tree
    return
  fi
  stage_adopter_tree csf4-migration
  log "pnpm install"
  run_logged "pnpm install" "$WORK/install.log" pnpm -C "$SCAFFOLD" install --frozen-lockfile
  log "playwright install chromium"
  run_logged "playwright install chromium" "$WORK/chromium.log" install_chromium "$SCAFFOLD"
  # Vite discovers dependencies while the first stories load, and the re-bundle
  # it triggers fails every story file of that run. Paying it here keeps it out
  # of the first run the command verifies.
  log "warm the Storybook dependency cache"
  csf4_vitest_report "$WORK/warm-report.json"
  csf4_git add -A
  csf4_git commit -q -m "staged release tree"
  BASE_COMMIT="$(csf4_git rev-parse HEAD)"
  # Lets the load-failure guard be shown against a different command build.
  GAIA="${GAIA_CSF4_BINARY:-$GAIA}"
}

# Untracked files are removed but ignored ones (node_modules, typegen) stay, so
# the install is paid once.
csf4_reset_tree() {
  csf4_git reset -q --hard "$BASE_COMMIT"
  csf4_git clean -fdq
}

csf4_commit() {
  csf4_git add -A
  csf4_git commit -q --allow-empty -m "$1"
}

csf4_drop_stories() {
  find "$FRONTEND/app" -name '*.stories.tsx' -delete
}

csf4_install_fixture() {
  local source_dir="$1" old_name
  rsync -a "$source_dir"/ "$FRONTEND"/
  while IFS= read -r old_name; do
    mv "$old_name" "${old_name%.csf?}"
  done < <(find "$FRONTEND/app" -name '*.stories.tsx.csf3' -o -name '*.stories.tsx.csf2')
}

# Copies one component directory (its index and stories) out of a fixture set.
csf4_install_component() {
  local fixture_set="$1" component="$2" target="$FRONTEND/app/components/$2"
  mkdir -p "$target"
  rsync -a "$FIXTURES/$fixture_set/app/components/$component"/ "$target"/
  find "$target" -name '*.stories.tsx.csf3' -o -name '*.stories.tsx.csf2' \
    | while IFS= read -r old_name; do mv "$old_name" "${old_name%.csf?}"; done
}

csf4_use_config() {
  cp "$FIXTURES/config/$1" "$FRONTEND/.storybook/preview.ts"
  # A main that lists the i18next addon is itself a sign the project uses it.
  if [ "${2:-}" = "no-i18n" ]; then
    grep -v 'storybook-react-i18next' "$FIXTURES/config/main.csf3.ts" > "$FRONTEND/.storybook/main.ts"
  else
    cp "$FIXTURES/config/main.csf3.ts" "$FRONTEND/.storybook/main.ts"
  fi
  # shellcheck disable=SC2016 # JavaScript source, not a shell expansion
  node -e '
    const fs = require("node:fs");
    const file = process.argv[1];
    const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
    delete manifest.imports;
    fs.writeFileSync(file, JSON.stringify(manifest, null, 2) + "\n");
  ' "$FRONTEND/package.json"
}

csf4_migrate() {
  MIGRATE_JSON="$WORK/migrate.json"
  MIGRATE_STDERR="$WORK/migrate-stderr.txt"
  MIGRATE_EXIT=0
  (cd "$SCAFFOLD" && "$GAIA" migrate-csf4 --json "$@" < /dev/null > "$MIGRATE_JSON" 2> "$MIGRATE_STDERR") \
    || MIGRATE_EXIT=$?
  [ -s "$MIGRATE_JSON" ] || { cat "$MIGRATE_STDERR" >&2; fail "migrate-csf4 printed no JSON"; exit 1; }
}

csf4_field() {
  json_get "$(cat "$MIGRATE_JSON")" "$1"
}

csf4_expect() {
  [ "$MIGRATE_EXIT" = "$2" ] || {
    cat "$MIGRATE_STDERR" >&2
    fail "$1: migrate-csf4 exited $MIGRATE_EXIT, expected $2 ($(cat "$MIGRATE_JSON"))"
    exit 1
  }
}

csf4_assert() {
  [ "$(csf4_field "$2")" = "$3" ] || {
    fail "$1: expected '$2' to be $3, got $(csf4_field "$2") ($(cat "$MIGRATE_JSON"))"
    exit 1
  }
}

csf4_fingerprint() {
  (
    cd "$SCAFFOLD" || exit 1
    git ls-files -z --cached --others --exclude-standard \
      | LC_ALL=C sort -z | xargs -0 "${SHA256_TOOL[@]}"
    git status --porcelain --untracked-files=all
  )
}

# Prints "<sha256>  <path>" for each scaffold-relative path listed in FILE.
csf4_hash_list() {
  (cd "$SCAFFOLD" && xargs "${SHA256_TOOL[@]}" < "$1")
}

csf4_story_files() {
  (cd "$SCAFFOLD" && git ls-files -z --cached --others --exclude-standard -- 'frontend/app/**/*.stories.tsx' | tr '\0' '\n' | sort)
}

csf4_vitest_report() {
  # A failing test or a file that cannot load makes Vitest exit non-zero; the
  # report is what the caller reads.
  pnpm -C "$FRONTEND" exec vitest run --project storybook \
    --reporter=json --outputFile="$1" < /dev/null > "$WORK/vitest.log" 2>&1 || true
  [ -s "$1" ] || { tail -n 40 "$WORK/vitest.log" >&2; fail "storybook vitest run wrote no report"; exit 1; }
}

# Prints "loaded passed" for a repo-relative story path from a Vitest JSON report.
csf4_report_status() {
  # shellcheck disable=SC2016 # the template literal is JavaScript, not shell
  node -e '
    const report = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    const match = report.testResults.find((result) => result.name.endsWith(process.argv[2]));
    const assertions = match ? match.assertionResults : [];
    const passed = assertions.length > 0 && assertions.every((test) => test.status === "passed");
    process.stdout.write(`${assertions.length > 0} ${passed}`);
  ' "$1" "$2"
}

csf4_story_check() {
  node "$HERE/lib/csf4-story-check.mjs" "$FRONTEND" "$@"
}
