#!/bin/bash
# GAIA update checker. The statusline's main-checkout render starts it detached.
#
# Writes .gaia/local/cache/shared/update-check.json with:
#   - outdatedCount  (actionable updates from `gaia update-deps run`, which
#                     applies the ESLint 9.x cap and the minimumReleaseAge
#                     cooldown, so it never counts updates the skill skips)
#   - gaiaCurrent    (from .gaia/VERSION)
#   - gaiaLatest     (from `gh release list` or curl GitHub API)
#   - gaiaHasUpdate  (semver comparison)
#   - codifyCandidateCount (recurring code-review findings ready to codify)
#   - codifyUnclassifiedCount (classless recurring findings over threshold;
#                     a seed-a-class-or-investigate signal, never a candidate)
#   - codifyNudgeReason (the composed text the /gaia-codify segment's Large
#                     form renders; the statusline also reads
#                     codifyCandidateCount directly for that segment's
#                     Medium form and icon count. codifyUnclassifiedCount
#                     keeps being written only for the upgrade-window seed:
#                     a cache written before codifyNudgeReason existed still
#                     has a value to seed the reason from on the first
#                     post-upgrade refresh)
#   - residueCandidateCount (keyed audit residue aged 30+ days, ready to
#                     triage via /gaia-residue)
#   - wikiDriftCount (non-bookkeeping commits the wiki trails HEAD by, from
#                     `gaia wiki state --json` drift_count; feeds the
#                     /gaia-wiki nudge)
#   - wikiStateSha   (the main checkout's wiki/.state.json last_evaluated_sha
#                     that wikiDriftCount was computed against)
#   - cleanseNudge / cleanseNudgeReason / cleanseLastAppliedAt / cleanseMemoryCount /
#                  cleanseMemoryBaseline (knowledge-cleanse drift signals)
#   - securityCount  (distinct open security advisories from `gaia update-deps
#                     advisories`; null, never 0, when no source answered)
#   - securitySource (dependabot, pnpm-audit, or unavailable)
#   - securityUnavailableReason (comma-joined closed-set reason tokens; empty
#                     for dependabot)
#   - gaiaOriginVersion (origin's default-branch .gaia/VERSION, from
#                     update-claim.sh; the previous value when the read fails)
#   - gaiaUpdateClaims (live update claims, open same-repo update/v* pull
#                     requests; [] when the list fails)
#   - ghLogin        (the current GitHub login; "" when unavailable, which
#                     hides the claim states)
#   - fitnessGrade / fitnessBlendCount / fitnessCommitCount /
#                     fitnessCommitThreshold / fitnessBlendLandedAt /
#                     fitnessBasisVersion / fitnessBasisCloseAt (the
#                     /gaia-fitness nudge signals, all measured against the
#                     main checkout; the statusline reads only these fields)
#   - checkedAt      (Unix epoch seconds)
#
# TTL is 6 hours (21600s). Re-runs within the TTL exit immediately so the
# statusline can start this in the background on every render without paying
# the cost each time. A cache with no securitySource key is treated as past its
# TTL once, so the first refresh after an upgrade fills the security fields. A
# cache whose wikiStateSha differs from the state file's is past its TTL too,
# and so is one whose fitnessBasisVersion differs from the main checkout's
# .gaia/VERSION (a cache with no such key, once). The blend record is
# deliberately not a basis: /update-gaia writes it before its own cache bust,
# so a record checksum here would undo that bust and recompute against a
# .gaia/VERSION that has not landed yet. A record change cannot raise the count
# before its update lands, and the landing changes .gaia/VERSION.
#
# Partial failures are tolerated; exit 0 even if some fields could not be
# refreshed. Do NOT add `set -e`.

TTL=21600

# Cleanse nudge thresholds. Tunable starting values:
#   - CLEANSE_DRIFT_DAYS: days since the last `applied` cleanse before signal (a) fires.
#   - CLEANSE_MEMORY_DELTA: memory entries gained since the last `applied` cleanse
#                         before signal (a) fires.
CLEANSE_DRIFT_DAYS=30
CLEANSE_MEMORY_DELTA=10

# Resolve project root (parent of .gaia/) so the script works regardless of cwd.
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAIA_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
PROJECT_ROOT="$(cd "$GAIA_DIRECTORY/.." && pwd)"

# cache/shared/ is registry scope `shared`: one physical copy per clone, which
# the statusline reads by resolving the main checkout. This script's own
# location answers "which tree am I in", never "where does shared state live",
# so a copy running inside a worktree must ask the resolver the same question
# the reader asks. Degrade-to-local rather than fail, matching
# .gaia/statusline/gaia-statusline.sh: with no resolver to ask, the local root
# is the honest answer and the refresher still refreshes.
#
# STATE_ROOT anchors machine-local STATE, and the one fitness check that
# serves both the cleanse and the fitness nudges. Everything else this script
# measures out of the checkout itself -- the CLI invocations below that name
# PROJECT_ROOT -- stays on PROJECT_ROOT,
# because those are tracked files that legitimately differ per branch.
# Repointing them wholesale would make this refresher report a fact about a
# tree nobody is in. The fitness check runs against STATE_ROOT because the
# fitness nudge is a fact about the main checkout's history; that is harmless
# for the cleanse nudge in production, since the statusline launches the main
# checkout's own copy of this refresher, so STATE_ROOT and PROJECT_ROOT are the
# same tree there.
if [ -f "$GAIA_DIRECTORY/scripts/main-root-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$GAIA_DIRECTORY/scripts/main-root-lib.sh" 2>/dev/null || true
fi
STATE_ROOT=""
if command -v gaia_resolve_main_root >/dev/null 2>&1; then
  STATE_ROOT="$(gaia_resolve_main_root "$PROJECT_ROOT" 2>/dev/null || true)"
fi
[ -n "$STATE_ROOT" ] || STATE_ROOT="$PROJECT_ROOT"

CACHE_DIRECTORY="$STATE_ROOT/.gaia/local/cache/shared"
CACHE_FILE="$CACHE_DIRECTORY/update-check.json"
VERSION_FILE="$GAIA_DIRECTORY/VERSION"
# The review snapshot lives at registry scope "shared", same anchor as the
# cache: one physical copy per clone, under the main checkout.
CODIFY_SNAPSHOT_FILE="$STATE_ROOT/.gaia/local/codify/reviewed.json"
# The first codify-tally run on a tree that still keeps its state in the old
# directory moves it into place after this script has read the token. Reading
# the old file when the new one is absent keeps the token identical across
# that move, so the race check below does not mistake the move for a review.
CODIFY_SNAPSHOT_OLD_FILE="$STATE_ROOT/.gaia/local/harden/reviewed.json"
codify_snapshot_token() {
  local snapshot_file="$CODIFY_SNAPSHOT_FILE"
  [ -f "$snapshot_file" ] || snapshot_file="$CODIFY_SNAPSHOT_OLD_FILE"
  [ -f "$snapshot_file" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -r '.reviewed_at // empty' "$snapshot_file" 2>/dev/null
}

# Source the fitness-nudge signal library. Guarded so a missing library never
# breaks the refresher: without it every fitness field carries its previous
# cached value.
FITNESS_NUDGE_LIBRARY="$GAIA_DIRECTORY/scripts/fitness-nudge-lib.sh"
# shellcheck source=.gaia/scripts/fitness-nudge-lib.sh
[ -f "$FITNESS_NUDGE_LIBRARY" ] && . "$FITNESS_NUDGE_LIBRARY"

# Today's codify-nudge count text: shared by the no-snapshot composition
# below and the upgrade-window seed for a cache written before
# codifyNudgeReason existed, so the two cannot drift out of step with each
# other. gaia-statusline-right.sh keeps its own copy of this composition for its
# legacy-cache fallback; codify-nudge-reason.bats pins both surfaces to the
# same rendered text.
codify_count_reason() {
  local count="$1" unclassified="$2" reason="" noun
  if [ "$count" -gt 0 ] 2>/dev/null; then
    noun="recurring patterns"
    [ "$count" -eq 1 ] && noun="recurring pattern"
    reason=$(printf '%d %s' "$count" "$noun")
  fi
  if [ "$unclassified" -gt 0 ] 2>/dev/null; then
    [ -n "$reason" ] && reason="${reason}, "
    reason=$(printf '%s%d unclassified' "$reason" "$unclassified")
  fi
  printf '%s' "$reason"
}

now=$(date +%s)

# Fingerprint of the cache as this run read it; empty when there is no cache.
# The pre-write check below compares it to catch a writer that does not take
# the refresh lock.
cache_fingerprint() {
  [ -f "$CACHE_FILE" ] || return 0
  cksum < "$CACHE_FILE" 2>/dev/null
}
cache_fingerprint_before="$(cache_fingerprint)"

# Read previous cache values (used as fallbacks on partial failure).
previous_checked_at=0
previous_outdated_count=0
previous_gaia_latest=""
previous_origin_version=""
previous_codify_count=0
previous_codify_unclassified=0
previous_codify_reason=""
previous_residue_count=0
previous_wiki_drift_count=0
previous_cleanse_last_applied_at=0
previous_cleanse_memory_count=0
previous_cleanse_memory_baseline=0
previous_fitness_grade=""
previous_fitness_blend_count=0
previous_fitness_commit_count=0
previous_fitness_blend_landed='{}'
previous_fitness_basis_close_at=0
# The cache's own checkedAt as this run read it, before any staleness gate below
# zeroes previous_checked_at: the pre-write bust check compares against it.
cache_checked_at_before=0
if [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1; then
  previous_checked_at=$(jq -r '.checkedAt // 0' "$CACHE_FILE" 2>/dev/null)
  previous_outdated_count=$(jq -r '.outdatedCount // 0' "$CACHE_FILE" 2>/dev/null)
  # No prev_ seed for gaiaCurrent or gaiaHasUpdate, unlike their siblings here:
  # gaiaCurrent is read from the local .gaia/VERSION file (authoritative; a stale
  # cached value would be worse than none), and gaiaHasUpdate is derived from
  # gaia_current + gaia_latest, both of which already carry their own fallbacks.
  previous_gaia_latest=$(jq -r '.gaiaLatest // ""' "$CACHE_FILE" 2>/dev/null)
  previous_origin_version=$(jq -r '.gaiaOriginVersion // ""' "$CACHE_FILE" 2>/dev/null)
  previous_codify_count=$(jq -r '.codifyCandidateCount // 0' "$CACHE_FILE" 2>/dev/null)
  previous_codify_unclassified=$(jq -r '.codifyUnclassifiedCount // 0' "$CACHE_FILE" 2>/dev/null)
  # A cache written before codifyNudgeReason existed (the upgrade window) has
  # no key to read, so seed it from the counts it does carry with today's
  # composition, never "": otherwise the first refresh after an upgrade that
  # fails to read codify-tally would write an empty reason and silently drop a
  # nudge the old cache was showing.
  if jq -e 'has("codifyNudgeReason")' "$CACHE_FILE" >/dev/null 2>&1; then
    previous_codify_reason=$(jq -r '.codifyNudgeReason // ""' "$CACHE_FILE" 2>/dev/null)
  else
    previous_codify_reason=$(codify_count_reason "$previous_codify_count" "$previous_codify_unclassified")
  fi
  previous_residue_count=$(jq -r '.residueCandidateCount // 0' "$CACHE_FILE" 2>/dev/null)
  previous_wiki_drift_count=$(jq -r '.wikiDriftCount // 0' "$CACHE_FILE" 2>/dev/null)
  previous_cleanse_last_applied_at=$(jq -r '.cleanseLastAppliedAt // 0' "$CACHE_FILE" 2>/dev/null)
  previous_cleanse_memory_count=$(jq -r '.cleanseMemoryCount // 0' "$CACHE_FILE" 2>/dev/null)
  previous_cleanse_memory_baseline=$(jq -r '.cleanseMemoryBaseline // 0' "$CACHE_FILE" 2>/dev/null)
  previous_fitness_grade=$(jq -r '.fitnessGrade | if type == "string" then . else "" end' "$CACHE_FILE" 2>/dev/null)
  previous_fitness_blend_count=$(jq -r '.fitnessBlendCount // 0' "$CACHE_FILE" 2>/dev/null)
  previous_fitness_commit_count=$(jq -r '.fitnessCommitCount // 0' "$CACHE_FILE" 2>/dev/null)
  previous_fitness_blend_landed=$(jq -c '.fitnessBlendLandedAt | if type == "object" then . else {} end' "$CACHE_FILE" 2>/dev/null)
  previous_fitness_basis_close_at=$(jq -r '.fitnessBasisCloseAt // 0' "$CACHE_FILE" 2>/dev/null)
  case "$previous_checked_at" in
    ''|*[!0-9]*) previous_checked_at=0 ;;
  esac
  cache_checked_at_before="$previous_checked_at"
  case "$previous_wiki_drift_count" in
    ''|*[!0-9]*) previous_wiki_drift_count=0 ;;
  esac
  case "$previous_cleanse_last_applied_at" in
    ''|*[!0-9]*) previous_cleanse_last_applied_at=0 ;;
  esac
  case "$previous_cleanse_memory_count" in
    ''|*[!0-9]*) previous_cleanse_memory_count=0 ;;
  esac
  case "$previous_cleanse_memory_baseline" in
    ''|*[!0-9]*) previous_cleanse_memory_baseline=0 ;;
  esac
  case "$previous_fitness_blend_count" in
    ''|*[!0-9]*) previous_fitness_blend_count=0 ;;
  esac
  case "$previous_fitness_commit_count" in
    ''|*[!0-9]*) previous_fitness_commit_count=0 ;;
  esac
  case "$previous_fitness_basis_close_at" in
    ''|*[!0-9]*) previous_fitness_basis_close_at=0 ;;
  esac
  [ -n "$previous_fitness_blend_landed" ] || previous_fitness_blend_landed='{}'
fi

# A cache written before the security fields existed is stale once, whatever
# its checkedAt says; the refresh that follows writes securitySource.
if [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1 \
  && ! jq -e 'has("securitySource")' "$CACHE_FILE" >/dev/null 2>&1; then
  previous_checked_at=0
fi

# The wiki state file advances by routes that never touch this cache (a hand
# `git pull`, a merge cleanup), so a cache computed against another state is
# stale whatever its age. Compared as a value, not a timestamp: the skills'
# cache-busts rewrite checkedAt and carry this field across unchanged.
wiki_state_sha=""
if command -v jq >/dev/null 2>&1; then
  wiki_state_sha=$(jq -r '.last_evaluated_sha // ""' "$STATE_ROOT/wiki/.state.json" 2>/dev/null)
  if [ -f "$CACHE_FILE" ] \
    && [ "$(jq -r '.wikiStateSha // ""' "$CACHE_FILE" 2>/dev/null)" != "$wiki_state_sha" ]; then
    previous_checked_at=0
  fi
fi

# The fitness signals are a function of the main checkout's .gaia/VERSION (a
# blended file counts only once main reaches its version), and a hand `git
# pull` moves that file by a route that never touches this cache. O(1) on
# purpose: this gate runs on every render, so it never reads the usage ledger
# or runs git. The close-row anchor is not a basis either: a fitness run busts
# the cache itself after it records its close row.
fitness_basis_version=""
if [ -f "$STATE_ROOT/.gaia/VERSION" ]; then
  fitness_basis_version=$(tr -d '[:space:]' < "$STATE_ROOT/.gaia/VERSION" 2>/dev/null)
fi
if [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1; then
  if ! jq -e 'has("fitnessBasisVersion")' "$CACHE_FILE" >/dev/null 2>&1 \
    || [ "$(jq -r '.fitnessBasisVersion // ""' "$CACHE_FILE" 2>/dev/null)" != "$fitness_basis_version" ]; then
    previous_checked_at=0
  fi
fi

# TTL gate.
age=$((now - previous_checked_at))
if [ "$age" -lt "$TTL" ]; then
  exit 0
fi

# Race token: the review snapshot's own reviewed_at, read here (past the TTL
# gate, since only a refresh needs it) and again right before the cache
# write. Plain string equality only (a completed review clears the cache
# directly, this is not the clock the TTL gate uses), empty on an absent,
# unparseable, or field-missing snapshot.
snapshot_token_before="$(codify_snapshot_token)"

mkdir -p "$CACHE_DIRECTORY" 2>/dev/null

# Single-flight lock. The statusline fires this script on every render, and
# the TTL gate above reads `checkedAt`, which is only written when a run
# finishes, so without a lock every render during a run launches another full
# run, each paging the merged-PR window through gh. `mkdir` is the atomic
# test-and-set. A lock older than LOCK_STALE_MINUTES belongs to a run that was
# killed before its EXIT trap fired, or one stalled on the network (nothing
# here carries a timeout); it is renamed aside and retaken, so a crash cannot
# block every future refresh. Held or lost: exit 0 and leave the cache to the
# run that holds it.
#
# The staleness probe and the rename are separate steps: two contenders can
# see the same stale lock, and by the time the slower one renames, the faster
# one has already retaken a live lock in its place. So the staleness is
# re-checked on the renamed directory (a rename keeps its mtime), and a live
# lock is handed back. The owner file covers the other half: a stalled holder
# whose lock was reclaimed removes the lock on exit only while it still holds
# it, never a successor's.
#
# Honest limit: a stalled holder keeps running after its lock is reclaimed,
# and a hand-back that loses to a third contender leaves that contender
# running beside the faster one. Each costs one duplicate refresh, whose cache
# write is an atomic mv. And a contender that renames a lock aside in the
# instant between its taker's mkdir and owner write hands it back ownerless,
# so no run releases it and refreshes wait out LOCK_STALE_MINUTES.
LOCK_DIRECTORY="$CACHE_DIRECTORY/.update-check.lock"
LOCK_STALE_MINUTES=10
lock_is_stale() {
  [ -n "$(find "$1" -maxdepth 0 -mmin +"$LOCK_STALE_MINUTES" 2>/dev/null)" ]
}
if ! mkdir "$LOCK_DIRECTORY" 2>/dev/null; then
  if lock_is_stale "$LOCK_DIRECTORY" && mv "$LOCK_DIRECTORY" "$LOCK_DIRECTORY.stale.$$" 2>/dev/null; then
    if ! lock_is_stale "$LOCK_DIRECTORY.stale.$$"; then
      mv "$LOCK_DIRECTORY.stale.$$" "$LOCK_DIRECTORY" 2>/dev/null
      exit 0
    fi
    rm -rf "$LOCK_DIRECTORY.stale.$$" 2>/dev/null
    mkdir "$LOCK_DIRECTORY" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
printf '%s\n' "$$" > "$LOCK_DIRECTORY/owner" 2>/dev/null
trap '[ "$(cat "$LOCK_DIRECTORY/owner" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIRECTORY" 2>/dev/null' EXIT

# ---------- outdatedCount ----------
# Count only the updates /update-deps will actually apply. The `update-deps
# run` primitive runs the same Phase 1-3 filtering the skill does; the ESLint
# 9.x cap and the minimumReleaseAge cooldown (pnpm 11 rejects lockfile entries
# younger than the cooldown, so the flow skips them). Counting its emitted plan
# (wave members that are genuine upgrades) keeps the nudge from prodding for
# updates that would be skipped. Falls back to the previous cached count on any
# failure: missing binary, network error, parse error.
outdated_count="$previous_outdated_count"
GAIA_BIN="$GAIA_DIRECTORY/cli/gaia"
if [ -x "$GAIA_BIN" ] && command -v jq >/dev/null 2>&1; then
  updates_temporary_file="$(mktemp "$CACHE_DIRECTORY/.updates.XXXXXX" 2>/dev/null)"
  if [ -n "$updates_temporary_file" ]; then
    if (cd "$PROJECT_ROOT" && "$GAIA_BIN" update-deps run --emit-updates "$updates_temporary_file") >/dev/null 2>&1 && [ -s "$updates_temporary_file" ]; then
      # The payload's `actionable_count` already excludes packages the human
      # snoozed via /update-deps (the gitignored decline ledger) and counts only
      # genuine upgrades.
      parsed=$(jq '.actionable_count' "$updates_temporary_file" 2>/dev/null)
      case "$parsed" in
        ''|*[!0-9]*) ;;
        *) outdated_count="$parsed" ;;
      esac
    fi
    rm -f "$updates_temporary_file" 2>/dev/null
  fi
fi
case "$outdated_count" in
  ''|*[!0-9]*) outdated_count=0 ;;
esac

# ---------- securityCount / securitySource / securityUnavailableReason ----------
# Open security advisories, from the CLI verb that owns source selection and
# validation. A refresh that cannot get an answer writes null with a reason and
# never carries the previous count forward: a stale count would claim a
# certainty this run does not have. Reason tokens are checked against the
# closed set below before they reach the cache, so no payload string is ever
# written verbatim.
security_count="null"
security_source="unavailable"
security_reason="cli-failed"
if [ -x "$GAIA_BIN" ] && command -v jq >/dev/null 2>&1; then
  advisories_temporary_file="$(mktemp "$CACHE_DIRECTORY/.advisories.XXXXXX" 2>/dev/null)"
  if [ -n "$advisories_temporary_file" ]; then
    if (cd "$PROJECT_ROOT" && "$GAIA_BIN" update-deps advisories --emit "$advisories_temporary_file" --count-only) >/dev/null 2>&1 && [ -s "$advisories_temporary_file" ]; then
      advisories_parsed=$(jq -r '
        def allowed: ["gh-missing","gh-unauthenticated","no-remote","non-github-remote","alerts-disabled","forbidden","alerts-request-failed","alerts-invalid-response","pnpm-audit-failed","cli-failed","jq-missing"];
        ((.reasons // []) | if type == "array" then map(select(type == "string" and . as $token | allowed | index($token))) | join(",") else "" end) as $reasons
        | if (.source == "dependabot" or .source == "pnpm-audit") and (.count | type) == "number" and (.count == (.count | floor)) and .count >= 0
          then "\(.source)|\(.count | floor)|\($reasons)"
          elif .source == "unavailable" then "unavailable||\($reasons)"
          else empty end
      ' "$advisories_temporary_file" 2>/dev/null)
      case "$advisories_parsed" in
        dependabot\|*|pnpm-audit\|*)
          security_source="${advisories_parsed%%|*}"
          advisories_rest="${advisories_parsed#*|}"
          security_count="${advisories_rest%%|*}"
          security_reason="${advisories_rest#*|}"
          ;;
        unavailable\|*)
          security_source="unavailable"
          security_count="null"
          security_reason="${advisories_parsed#*|}"
          security_reason="${security_reason#|}"
          ;;
      esac
    fi
    rm -f "$advisories_temporary_file" 2>/dev/null
  fi
fi
case "$security_count" in
  null) ;;
  ''|*[!0-9]*) security_count="null"; security_source="unavailable"; security_reason="cli-failed" ;;
esac

# ---------- codifyCandidateCount / codifyUnclassifiedCount / codifyNudgeReason ----------
# Recurring-finding tally for the policy-memory loop. `codify-tally` reads the
# rolling 90-day merged-PR window via gh, counts distinct PRs per finding_class
# at any severity (severity_max is a running-max ranking signal, not an
# eligibility gate), drops promoted/suppressed classes, and emits
# candidate_count plus a separate `unclassified` recurrence signal (non-null
# only at/above the recurrence threshold). Runs in this same TTL pass; network
# is non-fatal: a gh failure yields candidate_count 0 and unclassified null,
# which this pass takes as the new counts. Falls back to the previous cached
# counts only on a missing binary or a parse error.
#
# codifyNudgeReason is the text the /gaia-codify segment's Large form
# renders; the statusline reads codifyCandidateCount directly for that
# segment's Medium form and icon count, and codifyUnclassifiedCount keeps
# being written only for the upgrade-window seed (see previous_codify_reason).
# Without a review snapshot (snapshot_present not true:
# no snapshot yet, or a pre-SPEC/mock binary), the reason is today's count
# text via codify_count_reason. With one, it names the trigger events
# codify-tally reports: schema_change, the new_class count, one
# "<last path segment of finding_class> rising" per rising_class in
# triggers[] order (the segment stripped to [A-Za-z0-9._-], since class
# names come from PR comments any author can write), then "unclassified
# rising"; empty when triggers is empty.
#
# snapshot_present and snapshot_reviewed_at are read from the tally JSON; the
# race check below (arm b) needs this run's own values to catch codify-tally's
# own snapshot reading disagreeing with the file the script re-reads before
# the write, a mismatch arm (a) cannot see because both of the script's own
# reads of that file agree with each other.
codify_count="$previous_codify_count"
unclassified_count="$previous_codify_unclassified"
codify_reason="$previous_codify_reason"
snapshot_present="false"
snapshot_reviewed_at=""
if [ -x "$GAIA_BIN" ] && command -v jq >/dev/null 2>&1; then
  tally_json="$(cd "$PROJECT_ROOT" && "$GAIA_BIN" codify-tally 2>/dev/null)"
  if [ -n "$tally_json" ]; then
    parsed=$(printf '%s' "$tally_json" | jq -r '.candidate_count // empty' 2>/dev/null)
    unclassified_parsed=$(printf '%s' "$tally_json" | jq -r '.unclassified.distinct_pr_count // 0' 2>/dev/null)
    snapshot_present=$(printf '%s' "$tally_json" | jq -r '.snapshot_present // false' 2>/dev/null)
    snapshot_reviewed_at=$(printf '%s' "$tally_json" | jq -r '.snapshot_reviewed_at // empty' 2>/dev/null)
    case "$parsed" in
      ''|*[!0-9]*) ;;
      *) codify_count="$parsed" ;;
    esac
    case "$unclassified_parsed" in
      ''|*[!0-9]*) ;;
      *) unclassified_count="$unclassified_parsed" ;;
    esac
    if [ "$snapshot_present" = "true" ]; then
      codify_reason=$(printf '%s' "$tally_json" | jq -r '
        [.triggers[]?] as $triggers
        | ($triggers | map(select(.type=="new_class")) | length) as $new_class_count
        | [
            (if ($triggers | any(.type=="schema_change")) then "tally changed" else empty end),
            (if $new_class_count > 0 then (if $new_class_count == 1 then "1 new pattern" else "\($new_class_count) new patterns" end) else empty end),
            ($triggers[] | select(.type=="rising_class") | (.finding_class | split("/") | last | gsub("[^A-Za-z0-9._-]"; "") | if . == "" then "a pattern" else . end) + " rising"),
            (if ($triggers | any(.type=="rising_unclassified")) then "unclassified rising" else empty end)
          ]
        | join(", ")
      ' 2>/dev/null)
    else
      codify_reason=$(codify_count_reason "$codify_count" "$unclassified_count")
    fi
  fi
fi
case "$codify_count" in
  ''|*[!0-9]*) codify_count=0 ;;
esac
case "$unclassified_count" in
  ''|*[!0-9]*) unclassified_count=0 ;;
esac

# ---------- residueCandidateCount ----------
# Aged-residue tally for the /gaia-residue nudge.
# `residue-tally --count-only` is mandatory here: the refresher must never
# do head-object resolution, which costs 8.6-15.5s per
# fetch and grows the object store from 7.4MB to 66MB over fourteen fetches;
# a refresher that resolves is the failure this flag exists to prevent. It
# emits `aged_candidate_count` (survivors whose age_days >= 30, computed over
# the full post-suppression population before the cap) and a `gh_ok` flag.
# On a gh/network failure it exits 0 emitting aged_candidate_count 0 and
# gh_ok false, so this consumer honors gh_ok and keeps the previous cached
# count rather than resetting the nudge to 0. `count_approximate` is always
# true in --count-only mode (a coordinate-only suppression match, not a
# resolved-content bind); it is informational for a human reading the
# tally's own JSON, never branched on here, and never written to this cache.
# Falls back to the previous cached count on any failure: missing binary,
# gh/network error (gh_ok false), parse error.
residue_count="$previous_residue_count"
if [ -x "$GAIA_BIN" ] && command -v jq >/dev/null 2>&1; then
  residue_json="$(cd "$PROJECT_ROOT" && "$GAIA_BIN" residue-tally --count-only 2>/dev/null)"
  if [ -n "$residue_json" ]; then
    parsed=$(printf '%s' "$residue_json" | jq -r '.aged_candidate_count // empty' 2>/dev/null)
    gh_ok=$(printf '%s' "$residue_json" | jq -r '.gh_ok // false' 2>/dev/null)
    if [ "$gh_ok" = "true" ]; then
      case "$parsed" in
        ''|*[!0-9]*) ;;
        *) residue_count="$parsed" ;;
      esac
    fi
  fi
fi
case "$residue_count" in
  ''|*[!0-9]*) residue_count=0 ;;
esac

# ---------- wikiDriftCount ----------
# Wiki drift is a fact about the main checkout's wiki/.state.json, so the CLI
# runs from STATE_ROOT, never PROJECT_ROOT: a refresher copy inside a linked
# worktree would otherwise report that worktree's branch. Carries the previous
# cached count forward on a missing binary, a non-zero exit, empty output, or a
# non-integer drift_count, so a transient failure never clears a showing nudge.
wiki_drift_count="$previous_wiki_drift_count"
if [ -x "$GAIA_BIN" ] && command -v jq >/dev/null 2>&1; then
  if wiki_state_json="$(cd "$STATE_ROOT" && "$GAIA_BIN" wiki state --json 2>/dev/null)" \
    && [ -n "$wiki_state_json" ]; then
    parsed=$(printf '%s' "$wiki_state_json" | jq -r '.drift_count // empty' 2>/dev/null)
    case "$parsed" in
      ''|*[!0-9]*) ;;
      *) wiki_drift_count="$parsed" ;;
    esac
  fi
fi
case "$wiki_drift_count" in
  ''|*[!0-9]*) wiki_drift_count=0 ;;
esac

# ---------- cleanseNudge ----------
# Three conservative knowledge-cleanse drift signals, computed here (never on the
# statusline hot path) into one verbatim reason string + the raw counters the
# debounce needs. All local file IO; missing dirs/files fall back to prev/zero,
# never fatal. Priority when several fire: draft-pending > new-memories >
# staleness > project drift (keeps the segment to one line).
#
# Last-cleanse anchor: the newest .gaia/local/cleanse/KNOWLEDGE-*.md whose frontmatter
# `status:` is `applied` or `applied-partial` (gitignored, machine-local). Its
# mtime is "last cleanse on this machine". Any report whose `status:` is
# `draft` sets the resume signal.
cleanse_last_applied_at="$previous_cleanse_last_applied_at"
cleanse_memory_count="$previous_cleanse_memory_count"
cleanse_memory_baseline="$previous_cleanse_memory_baseline"
cleanse_nudge=false
cleanse_nudge_reason=""

# (a) Memory entry count proxy: `.stores.memory.count` from the CLI inventory,
# so the nudge and /gaia-cleanse count the same files. When the bundle, node or
# jq cannot answer, the signal is skipped and the previous count stands; it is
# never read as zero.
#
# The memory dir is keyed by the tree's path SPELLING, so unlike everything
# else under .gaia/local this one is not reached through the worktree's
# shared-state symlink -- a worktree gets a genuinely different directory, and
# a freshly created worktree path has almost no memory history. Anchoring it to
# the main checkout (--root STATE_ROOT) keeps this a fact about the clone,
# which is what the shared cache it feeds is read as.
# Runs a CLI command with stdout captured to a temporary file in the cache
# directory, then hands the command's exit code and that file to a handler
# function. Does nothing without the bundle, jq or a temporary file, so the
# handler's variables keep their prior values.
run_cli_into_temporary_file() {
  local handler="$1"
  shift
  local output_file exit_code
  if ! { [ -x "$GAIA_BIN" ] && command -v jq >/dev/null 2>&1; }; then
    return 0
  fi
  output_file="$(mktemp "$CACHE_DIRECTORY/.cli-output.XXXXXX" 2>/dev/null)"
  [ -n "$output_file" ] || return 0
  "$@" >"$output_file" 2>/dev/null
  exit_code=$?
  "$handler" "$exit_code" "$output_file"
  rm -f "$output_file" 2>/dev/null
}

# shellcheck disable=SC2329 # called by name through run_cli_into_temporary_file
read_memory_count_from_inventory() {
  local exit_code="$1" inventory_file="$2" memory_count
  [ "$exit_code" -eq 0 ] || return 0
  memory_count=$(jq -r '.stores.memory.count | if type == "number" then floor else empty end' "$inventory_file" 2>/dev/null)
  case "$memory_count" in
    ''|*[!0-9]*) ;;
    *) cleanse_memory_count="$memory_count" ;;
  esac
}

run_cli_into_temporary_file read_memory_count_from_inventory \
  "$GAIA_BIN" fitness inventory --json --root "$STATE_ROOT"

# Newest `applied` cleanse report → its mtime is the last-cleanse timestamp.
# The one-time move of reports out of the old audit/ directory runs from
# PROJECT_ROOT, the checkout this script runs in: the move only happens from
# the main checkout, and STATE_ROOT is the main checkout even when this runs
# from a worktree. Its outcome never reaches the cache.
KNOWLEDGE_INVENTORY="$GAIA_DIRECTORY/scripts/knowledge-inventory.sh"
if [ -f "$KNOWLEDGE_INVENTORY" ]; then
  (cd "$PROJECT_ROOT" && bash "$KNOWLEDGE_INVENTORY" relocate-reports --root "$STATE_ROOT") >/dev/null 2>&1 || true
fi
applied_at=0
draft_pending=false
CLEANSE_DIRECTORY="$STATE_ROOT/.gaia/local/cleanse"
if [ -d "$CLEANSE_DIRECTORY" ]; then
  while IFS= read -r cleanse_report_file; do
    [ -f "$cleanse_report_file" ] || continue
    frontmatter_status=$(sed -n '1,/^---[[:space:]]*$/p' "$cleanse_report_file" 2>/dev/null \
      | grep -m1 -E '^status:[[:space:]]*' 2>/dev/null \
      | sed 's/^status:[[:space:]]*//' | tr -d '[:space:]')
    if [ "$frontmatter_status" = "applied" ] || [ "$frontmatter_status" = "applied-partial" ]; then
      if [ "$applied_at" -eq 0 ] 2>/dev/null; then
        modification_epoch=$(stat -c %Y "$cleanse_report_file" 2>/dev/null || stat -f %m "$cleanse_report_file" 2>/dev/null)
        case "$modification_epoch" in
          ''|*[!0-9]*) ;;
          *) applied_at="$modification_epoch" ;;
        esac
      fi
    elif [ "$frontmatter_status" = "draft" ]; then
      draft_pending=true
    fi
  done < <(ls -t "$CLEANSE_DIRECTORY"/KNOWLEDGE-*.md 2>/dev/null)
fi
# Advance the last-applied anchor (and reset the memory baseline to the count at
# that cleanse) only when a newer applied report appears. This is the debounce:
# running a cleanse writes a fresh applied report, moving the anchor forward and
# resetting the baseline, which clears signal (a).
if [ "$applied_at" -gt "$cleanse_last_applied_at" ] 2>/dev/null; then
  cleanse_last_applied_at="$applied_at"
  cleanse_memory_baseline="$cleanse_memory_count"
fi

# (a) Per-machine drift, two independent arms, each surfacing its own label:
#   - memory_drift:  memory grew by >= CLEANSE_MEMORY_DELTA since the last applied cleanse
#   - time_drift: >= CLEANSE_DRIFT_DAYS elapsed since the last applied cleanse
# The fire thresholds (>= 10 memories, >= 30 days) guarantee both counts are
# plural, so the reason strings below carry no singular form.
memory_delta=$((cleanse_memory_count - cleanse_memory_baseline))
drift_seconds=$((CLEANSE_DRIFT_DAYS * 86400))
memory_drift=false
time_drift=false
days_since=0
if [ "$memory_delta" -ge "$CLEANSE_MEMORY_DELTA" ] 2>/dev/null; then
  memory_drift=true
fi
if [ "$cleanse_last_applied_at" -gt 0 ] 2>/dev/null \
  && [ "$((now - cleanse_last_applied_at))" -ge "$drift_seconds" ] 2>/dev/null; then
  time_drift=true
  days_since=$(( (now - cleanse_last_applied_at) / 86400 ))
fi

# (b) Project drift: any committed auto-load file over budget, judged by the
# CLI's budget rule so the numbers live in one place. Budget-only, no committed
# marker; clears for everyone once a dev fixes + commits. One adopter-scope
# fitness check serves both this nudge and the /gaia-fitness nudge, measured
# against the main checkout (STATE_ROOT). The default scope matters: findings
# in GAIA-shipped files land in `upstream` and do not move the overall grade
# the fitness nudge reports, while the budget count below still reads both
# lists. Exit 1 is shared with an unknown subcommand, so it counts as a result
# only when stdout parses as a check report; any other outcome leaves both
# signals as they were.
project_drift=false
fitness_report_usable=false
fitness_grade_computed=""
fitness_pathspecs=""
# shellcheck disable=SC2329 # called by name through run_cli_into_temporary_file
flag_project_drift_from_check_report() {
  local exit_code="$1" report_file="$2" budget_finding_count
  { [ "$exit_code" -eq 0 ] || [ "$exit_code" -eq 1 ]; } || return 0
  jq -e 'has("findings") and has("upstream")' "$report_file" >/dev/null 2>&1 || return 0
  budget_finding_count=$(jq -r '[.findings[], .upstream[]] | map(select(.rule_id == "claudemd.budget")) | length' "$report_file" 2>/dev/null)
  case "$budget_finding_count" in
    ''|*[!0-9]*|0) ;;
    *) project_drift=true ;;
  esac
  if command -v gaia_fitness_report_usable >/dev/null 2>&1 && gaia_fitness_report_usable "$report_file"; then
    if fitness_grade_computed="$(gaia_fitness_grade "$report_file")" \
      && fitness_pathspecs="$(gaia_fitness_harness_pathspecs "$report_file")"; then
      fitness_report_usable=true
    else
      fitness_grade_computed=""
      fitness_pathspecs=""
    fi
  fi
}

run_cli_into_temporary_file flag_project_drift_from_check_report \
  "$GAIA_BIN" fitness check --json --root "$STATE_ROOT"

# Pick the single highest-priority reason. The two machine-drift arms each get
# a self-describing label; when both fire, the concrete new-memory count wins.
if [ "$draft_pending" = "true" ]; then
  cleanse_nudge=true
  cleanse_nudge_reason="resume draft"
elif [ "$memory_drift" = "true" ]; then
  cleanse_nudge=true
  cleanse_nudge_reason="$memory_delta new memories"
elif [ "$time_drift" = "true" ]; then
  cleanse_nudge=true
  cleanse_nudge_reason="$days_since days since review"
elif [ "$project_drift" = "true" ]; then
  cleanse_nudge=true
  cleanse_nudge_reason="over budget"
fi

case "$cleanse_last_applied_at" in
  ''|*[!0-9]*) cleanse_last_applied_at=0 ;;
esac
case "$cleanse_memory_count" in
  ''|*[!0-9]*) cleanse_memory_count=0 ;;
esac
case "$cleanse_memory_baseline" in
  ''|*[!0-9]*) cleanse_memory_baseline=0 ;;
esac

# ---------- fitness nudge ----------
# Three reasons share one cached verdict: an adopter finding's grade, blended
# harness files an update left behind, and the team's harness commits since the
# last fitness run. Every git and file read is against STATE_ROOT, the main
# checkout. Each signal that cannot be read this run keeps its previous cached
# value, so a transient failure never arms or clears the nudge falsely; the
# ledger is the one input that gates two signals, so an unreadable ledger
# freezes both the blend and the commit count rather than counting the whole
# history.
fitness_threshold=15
fitness_grade="$previous_fitness_grade"
fitness_blend_count="$previous_fitness_blend_count"
fitness_commit_count="$previous_fitness_commit_count"
fitness_blend_landed="$previous_fitness_blend_landed"
fitness_basis_close_at="$previous_fitness_basis_close_at"
if command -v jq >/dev/null 2>&1 \
  && command -v gaia_fitness_newest_close >/dev/null 2>&1 \
  && command -v gaia_fitness_blend_signal >/dev/null 2>&1 \
  && command -v gaia_fitness_count_commits >/dev/null 2>&1 \
  && command -v gaia_fitness_commit_threshold >/dev/null 2>&1; then
  fitness_threshold="$(gaia_fitness_commit_threshold "$STATE_ROOT/.gaia/project.json")"
  [ "$fitness_report_usable" != "true" ] || fitness_grade="$fitness_grade_computed"
  fitness_close_epoch="$(gaia_fitness_newest_close "$STATE_ROOT/.gaia/local/telemetry/usage.jsonl")"
  fitness_ledger_status=$?
  if [ "$fitness_ledger_status" -eq 0 ]; then
    fitness_basis_close_at="${fitness_close_epoch:-0}"
    if fitness_blend_signal="$(gaia_fitness_blend_signal "$STATE_ROOT/.gaia/local/fitness/blend-record.json" \
      "$fitness_basis_version" "$fitness_close_epoch" "$previous_fitness_blend_landed" "$now")"; then
      fitness_blend_parsed="$(printf '%s' "$fitness_blend_signal" | jq -r '.count' 2>/dev/null)"
      fitness_landed_parsed="$(printf '%s' "$fitness_blend_signal" | jq -c '.landed | if type == "object" then . else empty end' 2>/dev/null)"
      case "$fitness_blend_parsed" in
        ''|*[!0-9]*) ;;
        *)
          if [ -n "$fitness_landed_parsed" ]; then
            fitness_blend_count="$fitness_blend_parsed"
            fitness_blend_landed="$fitness_landed_parsed"
          fi
          ;;
      esac
    fi
    if [ "$fitness_report_usable" = "true" ]; then
      fitness_pathspec_list=()
      while IFS= read -r fitness_pathspec; do
        [ -z "$fitness_pathspec" ] || fitness_pathspec_list+=("$fitness_pathspec")
      done <<<"$fitness_pathspecs"
      fitness_commits_parsed="$(gaia_fitness_count_commits "$STATE_ROOT" "$fitness_close_epoch" \
        "$GAIA_FITNESS_COMMIT_CAP" ${fitness_pathspec_list[@]+"${fitness_pathspec_list[@]}"})"
      case $? in
        0)
          case "$fitness_commits_parsed" in
            ''|*[!0-9]*) ;;
            *) fitness_commit_count="$fitness_commits_parsed" ;;
          esac
          ;;
        2) fitness_commit_count=0 ;;
      esac
    fi
  fi
fi
case "$fitness_threshold" in
  ''|*[!0-9]*|0) fitness_threshold=15 ;;
esac

# ---------- gaiaCurrent ----------
gaia_current=""
if [ -f "$VERSION_FILE" ]; then
  gaia_current=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null)
fi

# ---------- gaiaLatest ----------
gaia_latest=""
if command -v gh >/dev/null 2>&1; then
  gaia_latest=$(gh release list --repo gaia-react/gaia --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null)
fi
if [ -z "$gaia_latest" ] && command -v curl >/dev/null 2>&1; then
  if command -v jq >/dev/null 2>&1; then
    gaia_latest=$(curl -fsSL --max-time 5 https://api.github.com/repos/gaia-react/gaia/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
  else
    # Last-resort: grep the tag_name out of the JSON without jq.
    gaia_latest=$(curl -fsSL --max-time 5 https://api.github.com/repos/gaia-react/gaia/releases/latest 2>/dev/null \
      | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 \
      | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  fi
fi
# Strip leading 'v'.
gaia_latest="${gaia_latest#v}"
# Fall back to previous value if both fetchers failed (don't blank it).
if [ -z "$gaia_latest" ]; then
  gaia_latest="$previous_gaia_latest"
fi

# ---------- gaiaHasUpdate ----------
gaia_has_update=false
if [ -n "$gaia_current" ] && [ -n "$gaia_latest" ] && [ "$gaia_current" != "$gaia_latest" ]; then
  highest=$(printf '%s\n%s\n' "$gaia_current" "$gaia_latest" | sort -V | tail -1)
  if [ "$highest" = "$gaia_latest" ]; then
    gaia_has_update=true
  fi
fi

# ---------- gaiaOriginVersion, gaiaUpdateClaims, ghLogin ----------
# update-claim.sh owns the claim definition and every gh call it needs; every
# failure inside it comes back as an empty field, never a non-zero exit.
origin_version=""
update_claims_json="[]"
github_login=""
if command -v jq >/dev/null 2>&1; then
  claim_fields="$(bash "$SCRIPT_DIRECTORY/update-claim.sh" cache-fields --tree "$STATE_ROOT" 2>/dev/null)"
  if printf '%s' "$claim_fields" | jq -e 'type == "object" and (.gaiaUpdateClaims | type) == "array"' >/dev/null 2>&1; then
    origin_version=$(printf '%s' "$claim_fields" | jq -r '.gaiaOriginVersion // ""' 2>/dev/null)
    update_claims_json=$(printf '%s' "$claim_fields" | jq -c '.gaiaUpdateClaims' 2>/dev/null)
    github_login=$(printf '%s' "$claim_fields" | jq -r '.ghLogin // ""' 2>/dev/null)
  fi
fi
[ -n "$origin_version" ] || origin_version="$previous_origin_version"
[ -n "$update_claims_json" ] || update_claims_json="[]"

# ---------- codify reason race check ----------
# A completed review clears codifyNudgeReason in the cache directly (the
# /gaia-cleanse precedent), so a refresh already in flight when that happens
# must not overwrite the clear with a reason computed against the superseded
# snapshot. Re-read the snapshot's reviewed_at now and compare it, by plain
# string equality only, against two prior readings. Arm (a): the script's own
# startup read, catching a review landing between the script's two reads of
# the file. Arm (b): codify-tally's own read of the snapshot, catching that
# read disagreeing with the file the script re-reads here even when the
# script's two reads agree with each other, e.g. a resolver or root mismatch
# between the CLI and the script. Either mismatch: discard the reason and
# zero checkedAt rather than trust it. Only these two fields change on a
# race; every other field is written as computed. Honest limit: this
# compares reads taken at different times, so a review landing between the
# re-read below and the mv is not seen, and costs one stale render until the
# next refresh.
snapshot_token_now="$(codify_snapshot_token)"
checked_at_to_write="$now"
if [ "$snapshot_token_now" != "$snapshot_token_before" ] \
  || { [ "$snapshot_present" = "true" ] && [ "$snapshot_token_now" != "$snapshot_reviewed_at" ]; }; then
  codify_reason=""
  checked_at_to_write=0
fi

# ---------- concurrent cache write check ----------
# The skills' cache busts (update-check-bust.sh) take no lock: they rewrite
# the cache right after an update lands, while a refresh started earlier may
# still be running against the pre-update tree. That refresh's counts are
# older than the bust's, so when the cache changed since this run read it,
# the newer write wins and this run writes nothing. The bust carries every
# field it does not set and stamps checkedAt, so skipping costs at most one
# TTL of staleness in the fields this run would have refreshed. Honest limit:
# a write landing between this check and the mv below is still overwritten.
if [ "$(cache_fingerprint)" != "$cache_fingerprint_before" ]; then
  exit 0
fi

# A fitness run busts the cache (checkedAt 0) right after it records its close
# row, while a refresh that read the ledger earlier may still be running. This
# write rebuilds the whole object with a fresh checkedAt, which would replace
# that bust and hold a stale commit or blend reason for a full TTL. A cache
# that reads 0 now but did not at the start was busted mid-run: write 0 so the
# next render recomputes.
if [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1 \
  && [ "$cache_checked_at_before" != "0" ] \
  && [ "$(jq -r '.checkedAt // 0' "$CACHE_FILE" 2>/dev/null)" = "0" ]; then
  checked_at_to_write=0
fi

# ---------- Write cache atomically ----------
temporary_file="$(mktemp "$CACHE_DIRECTORY/.update-check.XXXXXX" 2>/dev/null)"
if [ -z "$temporary_file" ]; then
  temporary_file="$CACHE_FILE.tmp.$$"
fi

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --argjson checkedAt "$checked_at_to_write" \
    --argjson outdatedCount "$outdated_count" \
    --arg gaiaCurrent "$gaia_current" \
    --arg gaiaLatest "$gaia_latest" \
    --arg gaiaOriginVersion "$origin_version" \
    --argjson gaiaUpdateClaims "$update_claims_json" \
    --arg ghLogin "$github_login" \
    --argjson gaiaHasUpdate "$gaia_has_update" \
    --argjson codifyCandidateCount "$codify_count" \
    --argjson codifyUnclassifiedCount "$unclassified_count" \
    --arg codifyNudgeReason "$codify_reason" \
    --argjson residueCandidateCount "$residue_count" \
    --argjson wikiDriftCount "$wiki_drift_count" \
    --arg wikiStateSha "$wiki_state_sha" \
    --argjson cleanseNudge "$cleanse_nudge" \
    --arg cleanseNudgeReason "$cleanse_nudge_reason" \
    --argjson cleanseLastAppliedAt "$cleanse_last_applied_at" \
    --argjson cleanseMemoryCount "$cleanse_memory_count" \
    --argjson cleanseMemoryBaseline "$cleanse_memory_baseline" \
    --argjson securityCount "$security_count" \
    --arg securitySource "$security_source" \
    --arg securityUnavailableReason "$security_reason" \
    --arg fitnessGrade "$fitness_grade" \
    --argjson fitnessBlendCount "$fitness_blend_count" \
    --argjson fitnessCommitCount "$fitness_commit_count" \
    --argjson fitnessCommitThreshold "$fitness_threshold" \
    --argjson fitnessBlendLandedAt "$fitness_blend_landed" \
    --arg fitnessBasisVersion "$fitness_basis_version" \
    --argjson fitnessBasisCloseAt "$fitness_basis_close_at" \
    '{checkedAt: $checkedAt, outdatedCount: $outdatedCount, gaiaCurrent: $gaiaCurrent, gaiaLatest: $gaiaLatest, gaiaHasUpdate: $gaiaHasUpdate, gaiaOriginVersion: $gaiaOriginVersion, gaiaUpdateClaims: $gaiaUpdateClaims, ghLogin: $ghLogin, codifyCandidateCount: $codifyCandidateCount, codifyUnclassifiedCount: $codifyUnclassifiedCount, codifyNudgeReason: $codifyNudgeReason, residueCandidateCount: $residueCandidateCount, wikiDriftCount: $wikiDriftCount, wikiStateSha: $wikiStateSha, cleanseNudge: $cleanseNudge, cleanseNudgeReason: $cleanseNudgeReason, cleanseLastAppliedAt: $cleanseLastAppliedAt, cleanseMemoryCount: $cleanseMemoryCount, cleanseMemoryBaseline: $cleanseMemoryBaseline, securityCount: $securityCount, securitySource: $securitySource, securityUnavailableReason: $securityUnavailableReason, fitnessGrade: $fitnessGrade, fitnessBlendCount: $fitnessBlendCount, fitnessCommitCount: $fitnessCommitCount, fitnessCommitThreshold: $fitnessCommitThreshold, fitnessBlendLandedAt: $fitnessBlendLandedAt, fitnessBasisVersion: $fitnessBasisVersion, fitnessBasisCloseAt: $fitnessBasisCloseAt}' \
    > "$temporary_file" 2>/dev/null
else
  # jq not available; emit valid JSON via printf.
  # codify_reason is always the empty string on this path: both places that
  # compute it (the tally-driven composition above and the cache seed at
  # startup) require jq themselves, so neither branch ever runs without it.
  # Nothing here needs escaping.
  printf '{"checkedAt":%s,"outdatedCount":%s,"gaiaCurrent":"%s","gaiaLatest":"%s","gaiaHasUpdate":%s,"gaiaOriginVersion":null,"gaiaUpdateClaims":[],"ghLogin":"","codifyCandidateCount":%s,"codifyUnclassifiedCount":%s,"codifyNudgeReason":"%s","residueCandidateCount":%s,"wikiDriftCount":%s,"cleanseNudge":%s,"cleanseNudgeReason":"%s","cleanseLastAppliedAt":%s,"cleanseMemoryCount":%s,"cleanseMemoryBaseline":%s,"securityCount":null,"securitySource":"unavailable","securityUnavailableReason":"jq-missing"}\n' \
    "$checked_at_to_write" "$outdated_count" "$gaia_current" "$gaia_latest" "$gaia_has_update" "$codify_count" "$unclassified_count" "$codify_reason" "$residue_count" "$wiki_drift_count" "$cleanse_nudge" "$cleanse_nudge_reason" "$cleanse_last_applied_at" "$cleanse_memory_count" "$cleanse_memory_baseline" \
    > "$temporary_file" 2>/dev/null
fi

if [ -s "$temporary_file" ]; then
  mv "$temporary_file" "$CACHE_FILE" 2>/dev/null
else
  rm -f "$temporary_file" 2>/dev/null
fi

exit 0
