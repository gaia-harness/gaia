#!/usr/bin/env bash
# The act-on-home half: the home repository's gh identity, the slug
# comparison, and the URL-reference form of a merge selector.
# Sourced only by repo-scope.sh, whose header states the contract every
# consumer relies on; defines functions and globals and does no other work at
# source time.

# ---------------------------------------------------------------------------
# Act-on-home variant, for a consumer that ACTS on the home repo rather than
# blocking on it: posts a comment, strips a label. Same question, opposite
# fail direction and a different comparison.
#
# Fail direction. The guard resolves every ambiguity to 1 ("home"), so a
# blocking consumer keeps enforcing; over-enforcement is safe. Reading a foreign
# command as home is not safe for a consumer that acts: it writes to a pull
# request or an issue the command never named. So here every ambiguity resolves
# to 0 ("foreign") and the caller declines.
#
# The inversion reaches the whole question rather than one arm of it, because
# this entry point does not share the guard's arms. It reads the merge with the
# first-command scan, so a redirection ahead of the merge is not a shape
# it has to model: any prefix at all means the first command is not the merge,
# and it declines. `pushd`, a subshell `(cd ...`, and a `cd` to a path that does
# not resolve are each foreign here for that one reason, and so is a `-R`
# belonging to a later command in the same tool call.
#
# Comparison. gh identifies a repository as [HOST/]OWNER/REPO, so this compares
# the WHOLE value against one `gh repo view --json nameWithOwner,url` call,
# case-insensitively because GitHub resolves OWNER/REPO that way. The guard
# compares the repo-NAME half against the repository names the home
# repo's remotes point at, which reads a same-named fork
# (`--repo other-org/<homename>` from a clone of `<homename>`, the ordinary
# fork topology) as home. That is the safe direction there and the wrong one
# here.
#
# Usage (from a hook that acts on the home repo, after extracting $command):
#   _library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
#   [ -n "${_library_directory:-}" ] && [ -f "$_library_directory/repo-scope.sh" ] && . "$_library_directory/repo-scope.sh"
#   type command_targets_foreign_repo_slug >/dev/null 2>&1 || exit 0  # undefined: decline
#   if command_targets_foreign_repo_slug "$command"; then exit 0; fi      # foreign: decline
#
# The `type` guard is not optional decoration. Sourcing this lib cwd-relative
# and then writing `type f >/dev/null 2>&1 && f "$command"` falls THROUGH to acting
# when the source misses, which is the fail-open composition of a missing
# boundary check and a consumer that acts. Source from ${BASH_SOURCE[0]} and
# treat undefined as a reason to exit.

# Home identity, resolved at most once per process. `gh repo view` is a network
# call, and a caller that also needs the slug itself (issue-claim-release.sh
# pins both its read and its write to it) would otherwise pay for a second one.
GAIA_REPO_SCOPE_HOME_SLUG=""
GAIA_REPO_SCOPE_HOME_HOST=""
_gaia_repo_scope_home_tried=""

# Returns 0 with both globals populated, 1 when the home repo cannot be
# identified. A failed resolution is remembered too, so a caller in a repo gh
# cannot resolve does not retry the call on every question.
gaia_repo_scope_resolve_home() {
  if [ -n "$_gaia_repo_scope_home_tried" ]; then
    [ -n "$GAIA_REPO_SCOPE_HOME_SLUG" ] || return 1
    return 0
  fi
  _gaia_repo_scope_home_tried=1

  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local json url
  json=$(gh repo view --json nameWithOwner,url 2>/dev/null) || return 1
  GAIA_REPO_SCOPE_HOME_SLUG=$(printf '%s' "$json" | jq -r '.nameWithOwner // ""' 2>/dev/null)
  [ -n "$GAIA_REPO_SCOPE_HOME_SLUG" ] || return 1

  # The host is the URL's authority: an adopter mirroring one repository
  # between github.com and an enterprise host carries the same OWNER/REPO on
  # both, so the slug alone does not name it.
  url=$(printf '%s' "$json" | jq -r '.url // ""' 2>/dev/null)
  url="${url#*://}"
  GAIA_REPO_SCOPE_HOME_HOST=$(printf '%s' "${url%%/*}" | tr '[:upper:]' '[:lower:]')
  if [ -z "$GAIA_REPO_SCOPE_HOME_HOST" ]; then
    GAIA_REPO_SCOPE_HOME_SLUG=""
    return 1
  fi
  return 0
}

# Compare ONE already-extracted [HOST/]OWNER/REPO value against the home repo.
# 0 = foreign (decline), 1 = home. An EMPTY value means the command named no
# explicit target, which is home: gh resolves from cwd there.
#
# This is the half a consumer that parses the command itself wants. A regex
# over the raw command text cannot tell which command in a multi-command string
# a flag belongs to, so `gh pr merge 5; gh issue list --repo other/x` reads as
# foreign under a whole-string capture while the merge itself targets home. A
# caller holding a properly scanned value passes it here and skips that class
# of misread entirely.
repo_slug_is_foreign() {
  local value="$1"
  local command_host

  [ -n "$value" ] || return 1

  gaia_repo_scope_resolve_home || return 0

  # A host-qualified value is HOST/OWNER/REPO, and the host half decides as
  # much as the slug does: the same OWNER/REPO served from another host is
  # another repository. Accept the qualifier only when it names the home host,
  # and decline otherwise rather than dropping it and comparing what is left.
  case "$value" in
    */*/*)
      command_host=$(printf '%s' "${value%%/*}" | tr '[:upper:]' '[:lower:]')
      [ "$command_host" = "$GAIA_REPO_SCOPE_HOME_HOST" ] || return 0
      value="${value#*/}"
      ;;
  esac

  # Case-insensitive: GitHub resolves OWNER/REPO that way, so a merge spelled
  # in another case lands on the home repository and a case-sensitive
  # comparison would read it as a different one.
  [ "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" \
    = "$(printf '%s' "$GAIA_REPO_SCOPE_HOME_SLUG" | tr '[:upper:]' '[:lower:]')" ] || return 0
  return 1
}

# ---------------------------------------------------------------------------
# URL-reference form of the act-on-home question, shared by the same two
# consumers.
#
# gh takes `<number> | <url> | <branch>` as a merge selector, and a URL is the
# one form `-R`/`--repo` cannot qualify: gh resolves the repository from the
# URL itself and ignores the flag, so the scanned repository is empty and the
# comparison above reads it as home. A consumer that ACTS on the home
# repository therefore cannot take a URL's number at face value: a merged
# sibling-repository pull request read by URL would reach THIS repository's
# pull request or issue of the same number, because the write resolves here.
#
# Both consumers ask this of the identical scanned value, which is why the
# answer lives here beside the `-R`/`--repo` half rather than twice in them.
# The two halves are one boundary, and a boundary that answers the same
# question two different ways depending on which hook asks it is the failure
# a single definition rules out.
#
# Sets GAIA_HOME_PR_NUMBER and returns 0 when the reference is a URL naming
# the home repository. Returns 1 otherwise, which every caller reads as
# "decline": an unresolvable home, an unrecognized URL shape, another
# repository, and another host are all values no caller may act on.
GAIA_HOME_PR_NUMBER=""

gaia_gh_merge_reference_to_home_pr() {
  local reference="$1"
  local url_regex host slug number

  GAIA_HOME_PR_NUMBER=""

  gaia_repo_scope_resolve_home || return 1

  # Two shapes are matched as loosely as gh matches them; everywhere else this
  # stays deliberately tighter, so the first half is not a rule to follow gh
  # everywhere. gh's own URL matcher is `^/([^/]+)/([^/]+)/pull/(\d+)` against
  # the parsed path, UNANCHORED at the end, and it compares `u.Hostname()`,
  # which drops both a port and any userinfo.
  #
  # Followed: a `/`, `?`, or `#` suffix, the Files tab's own address being
  # `.../pull/7/files`, and a `:port` on the authority. gh merges the home
  # pull request each of those names, so declining one costs the consumer a
  # merge it should have acted on, which is the whole reason to loosen.
  #
  # Not followed: a suffix has to start with a separator, so `/pull/7files`
  # declines where gh's unanchored regex reads pull request 7, and userinfo
  # stays on the compared authority, so `https://user@github.com/...` declines
  # too. Every divergence that remains declines, which is this function's safe
  # direction, so each costs a silent no-op rather than a wrong write.
  #
  # That last sentence is why the scheme is `https?` and not a general scheme
  # class. gh reads only http and https as a URL and treats any other scheme
  # as a branch name, so a general class accepts `ftp://<home>/pull/7` and
  # hands back 7 for a reference gh never resolved: an ACCEPT where gh
  # declines, which is the one direction a boundary that acts cannot have.
  # Narrowing here keeps every divergence on the declining side.
  #
  # The bracketed spelling is a case-insensitive `https?`. A URL scheme is
  # case-insensitive and Go lowercases it before gh ever sees it, so a plain
  # `https?` would decline `HTTPS://<home>/pull/7`, which gh merges. The
  # alternative, `shopt -s nocasematch`, is process-global: it would also
  # reach the port strip below and every later `[[ ]]` in whichever hook
  # sourced this file.
  url_regex='^[hH][tT][tT][pP][sS]?://([^/]+)/([^/]+/[^/]+)/pull/([0-9]+)([/?#].*)?$'
  [[ "$reference" =~ $url_regex ]] || return 1
  host=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
  slug=$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')
  number="${BASH_REMATCH[3]}"

  # Drop a `:port` as gh's `u.Hostname()` does. Requiring digits after the
  # colon is what keeps this off a bracketed IPv6 authority's own colons:
  # `[::1]` ends in `]` and is left whole, `[::1]:443` ends in digits and
  # loses only the port. The home host never carries one, so a port left on
  # would simply never compare equal.
  if [[ "$host" =~ ^(.*):[0-9]+$ ]]; then
    host="${BASH_REMATCH[1]}"
  fi

  # The authority decides as much as the slug: the same OWNER/REPO served from
  # another host is another repository, and matching on the slug alone would
  # accept it. The slug comparison is case-insensitive because GitHub resolves
  # OWNER/REPO that way, so a URL spelled in another case lands on the home
  # repository and a case-sensitive comparison would cost the action.
  [ "$host" = "$GAIA_REPO_SCOPE_HOME_HOST" ] || return 1
  [ "$slug" = "$(printf '%s' "$GAIA_REPO_SCOPE_HOME_SLUG" | tr '[:upper:]' '[:lower:]')" ] || return 1

  # shellcheck disable=SC2034 # read by both sourcing consumers, never here
  GAIA_HOME_PR_NUMBER="$number"
  return 0
}
