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
#   - cached false: none. Project decisions are an admin's to record, so a
#     non-admin teammate would otherwise be nagged forever.
#   - no cached answer (no repo yet, so nothing has been probed): only
#     github-repository, which anyone can act on by creating or adopting one.
#
# Every input is read as text and parsed under try, so a missing or malformed
# file yields an empty set and never fails the caller's jq.

# shellcheck disable=SC2016 # jq variables, expanded by jq, not the shell.
GAIA_SETUP_OWED_JQ='
def gaia_setup_owed($list_text; $project_text):
  (if type == "object" then .admin else null end) as $admin
  | ((try ($project_text | fromjson | .setup_decisions) catch null)
     | if type == "object" then . else {} end) as $decided
  | [ try ($list_text | fromjson | .features | arrays | .[] | objects
           | select((.scope == "project") and ((.id | type) == "string")
                    and (($decided[.id] // "") | IN("applied", "declined", "not-applicable") | not))
           | .id) catch empty ]
  | if $admin == true then .
    elif $admin == false then []
    else map(select(. == "github-repository")) end;
'

# gaia_setup_owed_ids <repo root>: print the owed ids, space-separated, or
# nothing when none is owed.
gaia_setup_owed_ids() {
  local root="$1"
  [ -f "$root/.gaia/setup-features.json" ] || return 0
  jq -rn \
    --rawfile list "$root/.gaia/setup-features.json" \
    --arg project "$(cat "$root/.gaia/project.json" 2>/dev/null)" \
    --arg state "$(cat "$root/.gaia/local/setup-state.json" 2>/dev/null)" \
    "$GAIA_SETUP_OWED_JQ"' (try ($state | fromjson) catch {}) | gaia_setup_owed($list; $project) | join(" ")'
}
