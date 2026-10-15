# shellcheck shell=bash
# The pre-notebook locations of specs, plans and research, for the one-time
# move and for the notebook library's readiness gate. Sourced, never run: it
# defines functions and nothing else.
#
# This file is the one place outside the move script that spells the three old
# roots. Everything else asks these functions, so the retired-path check can
# hold every other library file to zero old-root text.
#
# Exit codes: 0 ok, 1 not pending (gaia_notebook_legacy_pending only), 2 usage.

# gaia_notebook_legacy_root <specs|plans|research> <main_root>
#   Prints the absolute old root of that kind under <main_root>.
gaia_notebook_legacy_root() {
  local kind="${1:-}" main_root="${2:-}"
  case "$kind" in specs | plans | research) ;; *) return 2 ;; esac
  [ -n "$main_root" ] || return 2
  printf '%s\n' "$main_root/.gaia/local/$kind"
}

# gaia_notebook_legacy_prefix <specs|plans|research>
#   Prints the repo-relative old prefix, trailing slash included, for text
#   matching (a memory file or a document citing the old location).
gaia_notebook_legacy_prefix() {
  case "${1:-}" in
    specs | plans | research) printf '%s\n' ".gaia/local/$1/" ;;
    *) return 2 ;;
  esac
}

# gaia_notebook_legacy_pending <main_root>
#   0 while a pre-notebook specs or plans ledger still exists under
#   <main_root>: the trigger for the library's fail-closed readiness gate.
#   Research had no ledger, so an old research folder alone never triggers it.
gaia_notebook_legacy_pending() {
  local main_root="${1:-}"
  [ -n "$main_root" ] || return 2
  [ -f "$main_root/.gaia/local/specs/ledger.json" ] || [ -f "$main_root/.gaia/local/plans/ledger.json" ]
}
