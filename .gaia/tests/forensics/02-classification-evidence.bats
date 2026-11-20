#!/usr/bin/env bats
# UAT-009: classification decision + evidence cite shape
# UAT-011: other class evidence cite
#
# DETECTOR/SURROGATE TEST (not the shipped skill): exercises an inline surrogate
# of the runbook branch and, where used, the `lib/*.sh` mirrors, never the shipped
# skill body. Real end-to-end guard: integration.md "Local skill end-to-end" diff.

HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LIBRARY_DIRECTORY="$HERE/lib"

setup() {
  # Source the classifier library (defines classify_description, classify_evidence)
  # shellcheck source=lib/classify.sh
  source "$LIBRARY_DIRECTORY/classify.sh"
}

# classify_case <description> <expected-class>
classify_case() {
  local class
  echo "case: \"$1\" classifies as $2"
  class="$(classify_description "$1")"
  [[ "$class" == "$2" ]]
}

# ---------------------------------------------------------------------------
# Classification table: each class matches its signal phrases, the first class
# in declared order wins a multi-match, and no match falls to other
# ---------------------------------------------------------------------------

@test "classify_description maps each description to its class (including multi-match order and other)" {
  classify_case "the init step failed" init || return 1
  classify_case "scaffold failed during setup" init || return 1
  classify_case "update conflict in hooks" update || return 1
  classify_case "there was a merge conflict" update || return 1
  classify_case "wiki-sync failed to push" wiki-sync || return 1
  classify_case "the sync operation timed out" wiki-sync || return 1
  classify_case "quality gate failed" quality-gate || return 1
  classify_case "typecheck errors appeared" quality-gate || return 1
  classify_case "the hook misfired" hook || return 1
  classify_case "PreToolUse rejected the call" hook || return 1
  classify_case "new-component skill failed" scaffold || return 1
  classify_case "vite crashed on startup" dev-server || return 1
  classify_case "port 5173 already in use" dev-server || return 1
  classify_case "init and update both mentioned" init || return 1
  classify_case "something went wrong that I cannot describe" other
}

# ---------------------------------------------------------------------------
# Evidence cite shape
# ---------------------------------------------------------------------------

@test "classify_evidence cites the signal phrase, or 'no taxonomy class matched' for other" {
  local evidence

  echo "case: evidence cite for init contains signal phrase"
  evidence="$(classify_evidence "init" "the init step failed")"
  [[ "$evidence" == *"init"* ]] || return 1

  echo "case: evidence cite for other is 'no taxonomy class matched'"
  evidence="$(classify_evidence "other" "something inexplicable happened")"
  [[ "$evidence" == "no taxonomy class matched" ]] || return 1

  echo "case: evidence cite for update contains signal phrase"
  evidence="$(classify_evidence "update" "merge conflict in hooks")"
  [[ "$evidence" == *"merge conflict"* ]]
}
