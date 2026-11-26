#!/usr/bin/env bats
# Doc-conformance: /gaia-fitness and /gaia-cleanse pass the authoring lint.
# 1. the committed CLI raises no `authoring.*` finding on the loaded set
# (commands plus `Read` targets, transitively); 2. each fitness/ and cleanse/
# sub-reference is linked from its entry.
# Assertion style: .claude/rules/bats-assertions.md.

# doc_fitness_descendants <pid>: every descendant pid of <pid>, one per line.
doc_fitness_descendants() {
  local child
  for child in $(pgrep -P "$1" || true); do
    printf '%s\n' "$child"
    doc_fitness_descendants "$child"
  done
}

# The CLI call is bounded: under the parallel whole-tree run it can sit idle
# with no output, so the whole run never finishes until someone kills it. A
# poll rather than timeout(1), which stock macOS lacks. The child process list
# printed before the kill is the clue to which call hung. The CLI runs without
# bats' fd 3 so no survivor can hold the run open.
setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLI_REPORT="$BATS_FILE_TMPDIR/check-report.json"
  local limit="${DOC_FITNESS_CHECK_TIMEOUT_SECONDS:-300}" cli_pid started="$SECONDS"
  local suite="${BATS_TEST_FILENAME#"$REPO_ROOT"/}"
  "$REPO_ROOT/.gaia/cli/gaia" fitness check --json --scope all \
    --config "$BATS_FILE_TMPDIR/no-such-config.json" \
    >"$CLI_REPORT" 2>"$BATS_FILE_TMPDIR/check-stderr.txt" </dev/null 3>&- &
  cli_pid=$!
  while kill -0 "$cli_pid" 2>/dev/null; do
    if [ $((SECONDS - started)) -ge "$limit" ]; then
      printf "%s: setup_file's gaia fitness check --json --scope all did not exit within %ss; killed it.\n" \
        "$suite" "$limit" >&2
      printf 'The CLI and its child processes when killed:\n' >&2
      ps -o pid,stat,etime,command -p "$cli_pid" >&2
      pgrep -P "$cli_pid" | while IFS= read -r child_pid; do
        ps -o pid=,stat=,etime=,command= -p "$child_pid" >&2
      done
      printf 'Next: re-run this suite alone with bash .gaia/scripts/bats5.sh %s; a pass alone means the hang needs parallel load, so file it as tech debt with the process list above.\n' "$suite" >&2
      # Kill every descendant, then the CLI; a no-match or a vanished pid must
      # not abort setup_file under errexit before the CLI is killed.
      local victims pid
      victims="$(doc_fitness_descendants "$cli_pid")"
      for pid in $victims "$cli_pid"; do
        kill -KILL "$pid" 2>/dev/null || true
      done
      wait "$cli_pid" 2>/dev/null || true
      return 1
    fi
    sleep 1
  done
  wait "$cli_pid" || true
  export CLI_REPORT
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLI_REPORT="$BATS_FILE_TMPDIR/check-report.json"
  FITNESS_ENTRY=".claude/skills/gaia/references/fitness.md"
  CLEANSE_ENTRY=".claude/skills/gaia/references/cleanse.md"
}

# read_targets <root> <file>: the repo-relative .md paths a `Read` line in
# <file> names, as `Read \`<path>\``, `Read $PROJECT_ROOT/<path>` or
# `Read $TREE_ROOT/<path>` (cleanse's Stage 2 reads from the isolated tree).
read_targets() {
  local root="$1" file="$2" target
  grep -oE 'Read (`|\$(PROJECT|TREE)_ROOT/)\.claude/[^` ]+\.md' "$root/$file" 2>/dev/null |
    sed -E 's/^Read (`|\$(PROJECT|TREE)_ROOT\/)//' |
    while IFS= read -r target; do
      [ -f "$root/$target" ] && printf '%s\n' "$target"
    done
  return 0
}

# loaded_set <root>: both command files and every file reachable from them
# through `Read` lines, one path per line, each once. Non-zero when the set
# lacks either entry playbook, so a derivation that found nothing cannot pass.
loaded_set() {
  local root="$1" queue seen="" current target
  queue=".claude/commands/gaia-fitness.md
.claude/commands/gaia-cleanse.md"
  while [ -n "$queue" ]; do
    current="${queue%%$'\n'*}"
    if [ "$queue" = "$current" ]; then queue=""; else queue="${queue#*$'\n'}"; fi
    case $'\n'"$seen"$'\n' in *$'\n'"$current"$'\n'*) continue ;; esac
    [ -f "$root/$current" ] || continue
    seen="${seen:+$seen$'\n'}$current"
    while IFS= read -r target; do
      [ -n "$target" ] && queue="${queue:+$queue$'\n'}$target"
    done < <(read_targets "$root" "$current")
  done
  printf '%s\n' "$seen"
  case $'\n'"$seen"$'\n' in *$'\n'"$FITNESS_ENTRY"$'\n'*) ;; *) return 1 ;; esac
  case $'\n'"$seen"$'\n' in *$'\n'"$CLEANSE_ENTRY"$'\n'*) ;; *) return 1 ;; esac
  return 0
}

# unlinked_references <root>: print each sub-reference its entry playbook does
# not link by repo-relative path. Non-zero when any is unlinked.
unlinked_references() {
  local root="$1" status=0 name entry file
  for name in fitness cleanse; do
    entry="$root/.claude/skills/gaia/references/$name.md"
    [ -d "$root/.claude/skills/gaia/references/$name" ] || continue
    for file in "$root/.claude/skills/gaia/references/$name"/*.md; do
      [ -e "$file" ] || continue
      if ! grep -qF -- ".claude/skills/gaia/references/$name/$(basename "$file")" "$entry"; then
        printf '%s\n' "${file#"$root"/}"
        status=1
      fi
    done
  done
  return "$status"
}

# bats test_tags=whole-tree
@test "the committed CLI raises no authoring finding against the loaded set" {
  [ -s "$CLI_REPORT" ]
  local set
  set="$(loaded_set "$REPO_ROOT")"
  [ -n "$set" ]
  jq -e '.findings | type == "array"' "$CLI_REPORT" >/dev/null
  local set_json hits
  set_json="$(jq -R . <<<"$set" | jq -s .)"
  hits="$(jq -r --argjson set "$set_json" \
    '.findings[] | select(.rule_id | startswith("authoring.")) | select(.file as $f | $set | index($f)) | "\(.rule_id) \(.file):\(.line)"' \
    "$CLI_REPORT")"
  [ -z "$hits" ] || { printf '%s\n' "$hits" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "every sub-reference is linked from its entry playbook" {
  [ -d "$REPO_ROOT/.claude/skills/gaia/references/cleanse" ]
  run unlinked_references "$REPO_ROOT"
  [ "$status" -eq 0 ]
}
