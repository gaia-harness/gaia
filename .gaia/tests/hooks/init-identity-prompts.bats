#!/usr/bin/env bats

# Doc pin for /gaia-init's project-identity block: every identity question it
# asks names at least two real options, and no option only points at the
# tool's own Other (an inert button that returns no value). Runs once on the
# real file (must pass) and on mutated scratch copies (must fail).

bats_require_minimum_version 1.5.0

INIT_DOC=.claude/commands/gaia-init.md
BLOCK_START='^### Q3–Q5, Project identity'
BLOCK_END='^### Q6,'

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRATCH="$BATS_TEST_TMPDIR/gaia-init.md"
  cp "$REPO_ROOT/$INIT_DOC" "$SCRATCH"
}

# identity_questions_ok <file>: prints each failure on stdout and returns 1
# when any asked question has fewer than two options or an option that
# points at Other. A question starts at a bold `**Qn, ...` line whose
# heading does not say it is derived; its options are the `- \`` lines up to
# the next question or the block's end.
identity_questions_ok() {
  BLOCK_START="$BLOCK_START" BLOCK_END="$BLOCK_END" awk '
    function close_question() {
      if (question != "" && options < 2) {
        print question ": " options " option(s)"
        failed = 1
      }
      question = ""
      options = 0
    }
    inside && $0 ~ ENVIRON["BLOCK_END"] { exit }
    !inside && $0 ~ ENVIRON["BLOCK_START"] { inside = 1; next }
    !inside { next }
    /^\*\*Q[0-9]/ {
      close_question()
      if ($0 !~ /not asked/) {
        match($0, /^\*\*[^*]+\*\*/)
        question = substr($0, 3, RLENGTH - 4)
        sub(/\.$/, "", question)
        asked++
      }
      next
    }
    question != "" && /^- `/ {
      options++
      if ($0 ~ /Other/) {
        print question ": option points at Other: " $0
        failed = 1
      }
    }
    END {
      close_question()
      if (!inside || asked == 0) {
        print "identity block or its questions not found"
        failed = 1
      }
      exit failed
    }
  ' "$1"
}

@test "real tree: every asked identity question names two real options" {
  run identity_questions_ok "$REPO_ROOT/$INIT_DOC"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "red twin: an identity question with one option fails" {
  sed '/^- `Set it later`/d' "$SCRATCH" >"$SCRATCH.new"
  mv "$SCRATCH.new" "$SCRATCH"
  run identity_questions_ok "$SCRATCH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Q3, GitHub username for CODEOWNERS: 1 option(s)"* ]]
}

@test "red twin: an option pointing at Other fails" {
  sed 's/^- `{folder name as-is}`.*/- `Enter another`: type a title via Other./' "$SCRATCH" >"$SCRATCH.new"
  mv "$SCRATCH.new" "$SCRATCH"
  run identity_questions_ok "$SCRATCH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"option points at Other"* ]]
}

@test "red twin: a missing identity block fails" {
  sed 's/^### Q3–Q5, Project identity/### Identity/' "$SCRATCH" >"$SCRATCH.new"
  mv "$SCRATCH.new" "$SCRATCH"
  run identity_questions_ok "$SCRATCH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}
