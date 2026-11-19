#!/usr/bin/env bats
#
# The sub-agent half of the context checkpoint has one tracked source for its
# numbers, .gaia/scripts/context-checkpoint-lib.sh. This suite scans two
# regions for literals that belong only there. Forbidden values are derived
# from the lib at test time (never typed here): the red, fire and skull bands
# on the default window and on a 200000 window, the default window and the
# three transcript bound constants.
#
# Regions and what each forbids:
#
# - hook: .claude/hooks/context-checkpoint-subagent.sh, the whole file with
#   comment lines included. Forbids each band value, the default window and
#   each bound as a whole word, and any assignment of a number to a name that
#   contains "yield".
# - helpers: the bodies of the lib's yield_limit, last_window, subagent_window
#   and transcript_reading functions (each from its opening line to the next
#   closing brace). Forbids the same as the hook.
#
# Numbers match as whole words (grep -wi). A region whose begin anchor is
# missing fails loudly, never as an empty pass.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/context-yield-single-source.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

HOOK_PATH=".claude/hooks/context-checkpoint-subagent.sh"
LIB_PATH=".gaia/scripts/context-checkpoint-lib.sh"
HELPERS_BEGIN='^gaia_context_(yield_limit|last_window|subagent_window|transcript_reading)\(\)'

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/$LIB_PATH"
  derive_forbidden
}

# add_band_values <window>: append that window's red, fire and skull values.
add_band_values() {
  local main_root="$BATS_TEST_TMPDIR/no-override" line red fire skull
  mkdir -p "$main_root"
  line="$(gaia_context_effective_line "$main_root" "$1")"
  read -r _ red fire skull <<<"$(gaia_context_bands "$1" "$line")"
  printf '%s\n%s\n%s\n' "$red" "$fire" "$skull" >>"$BAND_VALUES"
}

# derive_forbidden: build the forbidden word list from the lib.
derive_forbidden() {
  BAND_VALUES="$BATS_TEST_TMPDIR/band-values"
  HOOK_FORBIDDEN="$BATS_TEST_TMPDIR/hook-forbidden"
  : >"$BAND_VALUES"
  add_band_values "$GAIA_CONTEXT_DEFAULT_WINDOW"
  add_band_values 200000
  {
    cat "$BAND_VALUES"
    printf '%s\n' "$GAIA_CONTEXT_DEFAULT_WINDOW" "$GAIA_CONTEXT_TRANSCRIPT_HEAD_BYTES" \
      "$GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES" "$GAIA_CONTEXT_TRANSCRIPT_WIDE_BYTES"
  } >"$HOOK_FORBIDDEN"
}

# extract_helpers <lib file>: print the four helper bodies; fail if one is missing.
extract_helpers() {
  local count
  count="$(grep -cE "$HELPERS_BEGIN" "$1")"
  [ "$count" -eq 4 ] || { printf 'helper begin anchor not found in %s: %s of 4 helpers (%s)\n' "$1" "$count" "$HELPERS_BEGIN" >&2; return 1; }
  awk -v begin="$HELPERS_BEGIN" '$0 ~ begin {inside = 1} inside {print} inside && /^}/ {inside = 0}' "$1"
}

# check_region <hook|helpers> <file>: exit 0 when the region is clean,
# 1 with the offending lines (or the missing anchor) on stderr otherwise.
check_region() {
  local region_file="$BATS_TEST_TMPDIR/region.txt" hits
  case "$1" in
    hook) cp "$2" "$region_file" ;;
    helpers) extract_helpers "$2" >"$region_file" || return 1 ;;
    *) printf 'unknown region %s\n' "$1" >&2; return 2 ;;
  esac
  [ -s "$region_file" ] || { printf 'region %s is empty in %s\n' "$1" "$2" >&2; return 1; }
  hits="$(grep -nwiFf "$HOOK_FORBIDDEN" "$region_file" || true)"
  [ -z "$hits" ] || { printf 'forbidden literal in %s:\n%s\n' "$1" "$hits" >&2; return 1; }
  hits="$(grep -nE '[A-Za-z_]*[Yy][Ii][Ee][Ll][Dd][A-Za-z_]*=[0-9]' "$region_file" || true)"
  [ -z "$hits" ] || { printf 'yield-limit assignment in %s:\n%s\n' "$1" "$hits" >&2; return 1; }
}

@test "the hook spells no band value, window, bound or yield-limit assignment" {
  check_region hook "$REPO_ROOT/$HOOK_PATH"
}

@test "the new lib helper bodies spell no band value, window, bound or yield-limit assignment" {
  check_region helpers "$REPO_ROOT/$LIB_PATH"
}
