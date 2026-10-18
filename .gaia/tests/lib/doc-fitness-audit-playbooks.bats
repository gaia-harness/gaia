#!/usr/bin/env bats
# Doc-conformance: /gaia-fitness and /gaia-cleanse pass the authoring lint.
# 1. the loaded set (commands plus `Read` targets, transitively) is derived;
# 2. each file in it is under 500 lines; 3. the committed CLI raises no
# `authoring.*` finding on it; 4. each fitness/ and cleanse/ sub-reference is
# linked from its entry. Every invariant has a red twin on a scratch copy.
# Assertion style: .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLI_REPORT="$BATS_FILE_TMPDIR/check-report.json"
  "$REPO_ROOT/.gaia/cli/gaia" fitness check --json --scope all \
    --config "$BATS_FILE_TMPDIR/no-such-config.json" \
    >"$CLI_REPORT" 2>"$BATS_FILE_TMPDIR/check-stderr.txt" </dev/null || true
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

# over_limit <root> <file>...: print each file of 500 lines or more.
over_limit() {
  local root="$1" file lines status=0
  shift
  for file in "$@"; do
    lines="$(wc -l <"$root/$file" | tr -d ' ')"
    if [ "$lines" -ge 500 ]; then
      printf '%s has %s lines\n' "$file" "$lines"
      status=1
    fi
  done
  return "$status"
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

# scratch_tree: a scratch root holding only the command and playbook files.
scratch_tree() {
  local scratch="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$scratch/.claude/commands" "$scratch/.claude/skills/gaia"
  cp "$REPO_ROOT/.claude/commands/gaia-fitness.md" "$REPO_ROOT/.claude/commands/gaia-cleanse.md" "$scratch/.claude/commands/"
  cp -R "$REPO_ROOT/.claude/skills/gaia/references" "$scratch/.claude/skills/gaia/references"
  printf '%s\n' "$scratch"
}

@test "the loaded set is derived and holds both entry playbooks" {
  run loaded_set "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qxF -- "$FITNESS_ENTRY" <<<"$output"
  grep -qxF -- "$CLEANSE_ENTRY" <<<"$output"
  local sub
  for sub in "$REPO_ROOT"/.claude/skills/gaia/references/cleanse/*.md; do
    [ -e "$sub" ] || return 1
    grep -qxF -- "${sub#"$REPO_ROOT"/}" <<<"$output" || return 1
  done
}

@test "every file in the loaded set is under 500 lines" {
  local set
  set="$(loaded_set "$REPO_ROOT")"
  [ -n "$set" ]
  local -a files
  mapfile -t files <<<"$set"
  run over_limit "$REPO_ROOT" "${files[@]}"
  [ "$status" -eq 0 ]
}

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

@test "every sub-reference is linked from its entry playbook" {
  [ -d "$REPO_ROOT/.claude/skills/gaia/references/cleanse" ]
  run unlinked_references "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "red twin: a set member padded past 500 lines fails the line check" {
  local scratch file i
  scratch="$(scratch_tree)"
  file=".claude/skills/gaia/references/cleanse/research.md"
  for i in $(seq 1 300); do printf 'padding line %s\n' "$i" >>"$scratch/$file"; done
  run over_limit "$scratch" "$file"
  [ "$status" -eq 1 ]
  grep -qF -- "$file has" <<<"$output"
}

@test "red twin: an unlinked sub-reference fails the link check" {
  local scratch
  scratch="$(scratch_tree)"
  printf '# Orphan\n\nNothing links here.\n' >"$scratch/.claude/skills/gaia/references/cleanse/orphan.md"
  run unlinked_references "$scratch"
  [ "$status" -eq 1 ]
  grep -qF -- "cleanse/orphan.md" <<<"$output"
}

@test "red twin: commands with no Read line fail the derivation" {
  local scratch
  scratch="$(scratch_tree)"
  printf -- '---\ndescription: x\n---\nNothing is loaded here.\n' >"$scratch/.claude/commands/gaia-fitness.md"
  printf -- '---\ndescription: x\n---\nNothing is loaded here.\n' >"$scratch/.claude/commands/gaia-cleanse.md"
  run loaded_set "$scratch"
  [ "$status" -eq 1 ]
}
