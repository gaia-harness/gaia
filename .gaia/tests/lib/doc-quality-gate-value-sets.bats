#!/usr/bin/env bats
#
# The Quality Gate page's value-set step runs on every commit, ahead of the
# skip decision and inside the smaller gate, and blocks on exit 1 or 2. The test
# reads the page and audit-gate-owed.sh as the other doc-quality-gate suites do,
# and runs the committed gaia bundle in a tree it builds at run time.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE="$REPO_ROOT/wiki/decisions/Quality Gate.md"
  SCRIPT="$REPO_ROOT/.gaia/scripts/audit-gate-owed.sh"
  BUNDLE="$REPO_ROOT/.gaia/cli/gaia"
  TREE="$BATS_TEST_TMPDIR/tree"
}

# The fenced block that follows the given label line.
page_block() {
  awk -v label="$1:" '
    $0 == label { armed = 1; next }
    armed && /^```bash$/ { in_block = 1; next }
    in_block && /^```$/ { exit }
    in_block { print }
  ' "$PAGE"
}

# The paragraph of the page that opens with the bolded step name.
page_value_sets_paragraph() {
  grep -m1 '^\*\*Value sets\*\*' "$PAGE"
}

# The command the page states for the step: the first backticked `... value-sets`.
page_value_sets_command() {
  page_value_sets_paragraph | sed -n 's/^[^`]*`\([^`]* value-sets\)`.*/\1/p'
}

# A committed tree holding the bundle and scripts/lib.sh with an array.
build_tree() {
  mkdir -p "$TREE/.gaia/cli" "$TREE/scripts" "$TREE/wiki"
  cp "$BUNDLE" "$TREE/.gaia/cli/gaia"
  git -C "$TREE" init -q
  git -C "$TREE" config user.email t@example.com
  git -C "$TREE" config user.name T
  git -C "$TREE" config commit.gpgsign false
  printf 'kinds=(%s %s %s)\n' alpha beta gamma >"$TREE/scripts/lib.sh"
  git -C "$TREE" add -A
  git -C "$TREE" commit -q -m init
}

run_page_command() {
  local command
  command="$(page_value_sets_command)"
  [ -n "$command" ] || { echo "the page states no value-sets command"; return 1; }
  (cd "$TREE" && bash -c "$command" 2>&1)
}

# bats test_tags=whole-tree
@test "the value-set step runs on every commit before the skip decision and in the smaller gate, blocks on a duplicate, and leaves the Quick check unchanged" {
  local scratch="$BATS_TEST_TMPDIR/scratch" folder="$BATS_TEST_TMPDIR/run" repository="$BATS_TEST_TMPDIR/repo"
  local paragraph quick_check page_pattern script_pattern smaller output_text

  # The page states the step, the command and the blocking exit codes, before the skip logic.
  paragraph="$(page_value_sets_paragraph)"
  [ -n "$paragraph" ]
  printf '%s\n' "$paragraph" | grep -qF 'gaia value-sets' || { echo "no command"; return 1; }
  printf '%s\n' "$paragraph" | grep -qF 'whatever is staged' || { echo "not on every commit"; return 1; }
  printf '%s\n' "$paragraph" | grep -qF 'Exit 1 (findings) or 2 (cannot run) blocks the commit' || { echo "no blocking exits"; return 1; }
  [ "$(grep -n '^\*\*Value sets\*\*' "$PAGE" | head -1 | cut -d: -f1)" -lt "$(grep -n '^## When to skip the gate' "$PAGE" | head -1 | cut -d: -f1)" ]
  grep -qF '| Value sets ' "$PAGE" || { echo "no result row"; return 1; }
  grep -qF 'the value-set step runs even then' "$PAGE" || grep -qF 'The value-set step runs even then' "$PAGE" || { echo "skip section silent"; return 1; }

  # Only scripts/dup.sh staged, repeating the array from scripts/lib.sh: the step exits 1.
  build_tree
  printf 'copy=(%s %s %s)\n' gamma beta alpha >"$TREE/scripts/dup.sh"
  git -C "$TREE" add scripts/dup.sh
  run run_page_command
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  printf '%s\n' "$output" | grep -qF 'scripts/dup.sh' || { echo "dup.sh not named: $output"; return 1; }

  # The Quick check matches nothing for that staged set.
  quick_check="$(page_block "Quick check")"
  [ -n "$quick_check" ]
  output_text="$(cd "$TREE" && bash -c "$quick_check" || true)"
  [ -z "$output_text" ] || { echo "quick check selected: $output_text"; return 1; }

  # Only wiki pages staged on a clean tree: the step exits 0.
  git -C "$TREE" reset -q
  rm -f "$TREE/scripts/dup.sh"
  printf 'page\n' >"$TREE/wiki/a.md"
  git -C "$TREE" add wiki/a.md
  run run_page_command
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }

  # The smaller gate keeps the step: it runs every step but the ones it defers.
  smaller="$(awk '/^## The smaller gate/ { armed = 1; next } armed && /^## / { exit } armed { print }' "$PAGE")"
  printf '%s\n' "$smaller" | grep -qF 'the value-set step included' || { echo "smaller gate drops the step"; return 1; }
  printf '%s\n' "$smaller" | grep -qE 'steps 6, 7 and 8 \(Playwright, the dev smoke test, the production build\)' || { echo "deferred list changed"; return 1; }

  # The Quick check equals the script's pattern.
  page_pattern="$(printf '%s\n' "$quick_check" | sed -n "s/.*grep -E '\(.*\)'\$/\1/p")"
  script_pattern="$(sed -n "s/^GATE_QUICK_CHECK_PATTERN='\(.*\)'\$/\1/p" "$SCRIPT")"
  [ -n "$page_pattern" ]
  [ "$page_pattern" = "$script_pattern" ]

  # A round the script routes to the smaller gate gets the gate stated above.
  mkdir -p "$scratch" "$folder" "$repository"
  cp "$SCRIPT" "$scratch/audit-gate-owed.sh"
  printf '#!/usr/bin/env bash\ncat "%s/findings.json"\n' "$BATS_TEST_TMPDIR" >"$scratch/audit-loop-eval.sh"
  chmod +x "$scratch/audit-loop-eval.sh"
  git -C "$repository" init -q
  printf '{"round":1,"entries":[{"member":"m","finding_class":"c","path":"a.ts","line":1,"severity":"minor","security":false}],"missing_members":[]}\n' >"$BATS_TEST_TMPDIR/findings.json"
  printf '{"version":1,"entries":[{"member":"m","finding_class":"c","path":"a.ts","line":1,"disposition":"fix"}]}\n' >"$folder/dispositions-1.json"
  run bash "$scratch/audit-gate-owed.sh" choose --root "$repository" --run-folder "$folder" --round 1
  [ "$status" -eq 0 ]
  [ "$output" = smaller ]
}
