# shellcheck shell=bash
# The project-scope setup features still owed that this machine can act on.
# Two readers share this one predicate so they never disagree: the statusline's
# setup nudge counts it, and /setup-gaia's closing message names it through
# gaia_setup_owed_ids.
#
# An id is owed while `.gaia/project.json` `setup_decisions` holds no decision
# for it. Who can act on it comes from the `admin` answer `gaia setup
# check-admin` caches in `.gaia/local/setup-state.json`:
#   - cached true: every owed project id.
#   - cached false: none. Project decisions are an admin's to record, and
#     `/setup-gaia` cannot clear them for a non-admin, so a nudge here would
#     never go away. The admin's own machine caches true and counts them.
#   - no cached answer (no repo yet, so nothing has been probed): only
#     github-repository, which anyone can act on by creating or adopting one.
#
# gaia_setup_admin_owed_ids names the other half for the closing message: the
# admin-gated ids a cached non-admin cannot act on, so a non-admin run never
# ends on a done line while a protection such as the required CI checks is
# still unapplied. gaia_setup_admin_gated_ids names the same ids with no cached
# answer at all, for a run whose own admin probe failed: no answer is cached
# then, and the closing message knows from the run's host that the ids apply.
#
# Every input is read as text and parsed under try, so a missing or malformed
# file yields an empty set and never fails the caller's jq.

# shellcheck disable=SC2016 # jq variables, expanded by jq, not the shell.
GAIA_SETUP_OWED_JQ='
def gaia_setup_undecided_project($list_text; $project_text):
  ((try ($project_text | fromjson | .setup_decisions) catch null)
     | if type == "object" then . else {} end) as $decided
  | [ try ($list_text | fromjson | .features | arrays | .[] | objects
           | select((.scope == "project") and ((.id | type) == "string")
                    and (($decided[.id] // "") | IN("applied", "declined", "not-applicable") | not))) catch empty ];
def gaia_setup_owed($list_text; $project_text):
  (if type == "object" then .admin else null end) as $admin
  | [ gaia_setup_undecided_project($list_text; $project_text)[] | .id ]
  | if $admin == true then .
    elif $admin == false then []
    else map(select(. == "github-repository")) end;
def gaia_setup_admin_gated($list_text; $project_text):
  [ gaia_setup_undecided_project($list_text; $project_text)[] | select(.admin == true) | .id ];
def gaia_setup_admin_owed($list_text; $project_text):
  (if type == "object" then .admin else null end) as $admin
  | if $admin == false then gaia_setup_admin_gated($list_text; $project_text) else [] end;
'

# gaia_setup_ids_with <repo root> <jq def name>: print the ids the named def
# returns, space-separated, or nothing.
gaia_setup_ids_with() {
  local root="$1" definition="$2"
  [ -f "$root/.gaia/setup-features.json" ] || return 0
  jq -rn \
    --rawfile list "$root/.gaia/setup-features.json" \
    --arg project "$(cat "$root/.gaia/project.json" 2>/dev/null)" \
    --arg state "$(cat "$root/.gaia/local/setup-state.json" 2>/dev/null)" \
    "$GAIA_SETUP_OWED_JQ"' (try ($state | fromjson) catch {}) | '"$definition"'($list; $project) | join(" ")'
}

# gaia_setup_owed_ids <repo root>: print the owed ids, space-separated, or
# nothing when none is owed.
gaia_setup_owed_ids() {
  gaia_setup_ids_with "$1" gaia_setup_owed
}

# gaia_setup_admin_owed_ids <repo root>: print the admin-gated project ids a
# cached non-admin leaves owed, space-separated, or nothing.
gaia_setup_admin_owed_ids() {
  gaia_setup_ids_with "$1" gaia_setup_admin_owed
}

# gaia_setup_admin_gated_ids <repo root>: print every undecided admin-gated
# project id, whatever the cached admin answer, space-separated, or nothing.
gaia_setup_admin_gated_ids() {
  gaia_setup_ids_with "$1" gaia_setup_admin_gated
}
