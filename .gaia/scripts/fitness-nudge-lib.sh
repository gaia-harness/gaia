# shellcheck shell=bash
# Signals behind the statusline's /gaia-fitness nudge: the grade of a fitness
# report, the harness files it inventories, the team's harness commits since
# the last fitness run, and the blended-file record an update leaves behind.
#
# Sourced by the background refresher and the blend-record writer. Defines
# functions and two constants only; nothing runs at source time. bash 3.2
# compatible. Requires jq and git. Every function returns a status and never
# exits, so a caller under `set -e` decides what a refusal means.
#
# A "fitness report" is the JSON `fitness check --json` prints (default adopter
# scope): `.overall` string, `.findings[]` (`rule_id`, `ownership`, ...),
# `.upstream[]`, `.inventory[]` (`path`, `kinds`, `ownership`).

# shellcheck disable=SC2034 # read by the callers that source this file
GAIA_FITNESS_COMMIT_CAP=999
GAIA_FITNESS_DEFAULT_THRESHOLD=15

# Commit subjects a GAIA scaffold, init or update writes into the project's own
# history. Matched as literal prefixes, so a squash suffix (" (#<N>)") is
# tolerated. The last group is the 2.0.0 migration's commits.
GAIA_FITNESS_GAIA_SUBJECT_PREFIXES=(
  'chore: scaffold from GAIA '
  'chore: initialize project with /gaia-init'
  'chore(gaia): update to '
  'chore(gaia): start update to '
  'chore: update GAIA to '
  'chore: re-render code-review-audit.yml for '
  'chore: audit roster check'
  'chore: bump pnpm and Node for GAIA 2.0.0'
  'chore: drop the root React Doctor skill copy'
  'chore: meet @gaia-react/lint 3.0.0 rules'
  'chore: merge the GAIA 2.0.0 frontend'
  'chore: merge the GAIA 2.0.0 harness and split the workspace'
  'chore: point references at frontend/'
  'chore: upgrade to GAIA 2.0.0'
  'chore: upgrade the Serena project config'
)

# Inventory path prefixes that are never harness, as a JSON array for jq. An
# adopter clone has no test tree under .gaia, so the release keeps it empty.
GAIA_FITNESS_NON_HARNESS_PREFIXES='[]'
# gaia:maintainer-only:start
GAIA_FITNESS_NON_HARNESS_PREFIXES='[".gaia/tests/"]'
# gaia:maintainer-only:end

# 0 when the report is a JSON object with array findings, upstream and
# inventory and a string overall, and its inventory is not all "unknown"
# ownership (a failed ownership classifier); 1 otherwise.
gaia_fitness_report_usable() {
  jq -e '
    type == "object"
    and (.findings | type) == "array"
    and (.upstream | type) == "array"
    and (.inventory | type) == "array"
    and (.overall | type) == "string"
    and ((.inventory | length) == 0
         or (all(.inventory[]; .ownership == "unknown") | not))
  ' "$1" >/dev/null 2>&1 || return 1
}

# Prints .overall when a real adopter finding exists (anything but the
# CLAUDE.md budget rule); nothing otherwise. 1 when the file does not parse.
gaia_fitness_grade() {
  jq -r '
    if any(.findings[]; .ownership == "adopter" and .rule_id != "claudemd.budget")
    then .overall else empty end
  ' "$1" 2>/dev/null || return 1
}

# Harness paths, one per line, sorted and unique.
gaia_fitness_harness_paths() {
  local paths
  paths="$(jq -r --argjson skip "$GAIA_FITNESS_NON_HARNESS_PREFIXES" '
    .inventory[]
    | select((.kinds | index("wiki") | not)
             and ([.path as $path | $skip[] | . as $prefix | $path | startswith($prefix)] | any | not)
             and (.ownership != "third-party" and .ownership != "ignored"))
    | .path
  ' "$1" 2>/dev/null)" || return 1
  [ -n "$paths" ] || return 0
  printf '%s\n' "$paths" | LC_ALL=C sort -u
}

# Git pathspecs for the harness: includes, then excludes, each sorted and
# unique. Nothing at all when there is no include.
gaia_fitness_harness_pathspecs() {
  jq -r --argjson skip "$GAIA_FITNESS_NON_HARNESS_PREFIXES" '
    def harness:
      select((.kinds | index("wiki") | not)
             and ([.path as $path | $skip[] | . as $prefix | $path | startswith($prefix)] | any | not)
             and (.ownership != "third-party" and .ownership != "ignored"));
    ([.inventory[] | harness | .path
      | if test("^((.*/)?)\\.claude/[^/]+/.+") then
          capture("^(?<prefix>(.*/)?)\\.claude/(?<segment>[^/]+)/.+")
          | ":(glob)" + .prefix + ".claude/" + .segment + "/**/*.md"
        else ":(literal)" + . end] | unique) as $includes
    | ([.inventory[] | select(.ownership == "third-party") | .path
        | if test("^((.*/)?)\\.claude/skills/[^/]+/") then
            capture("^(?<prefix>(.*/)?)\\.claude/skills/(?<name>[^/]+)/")
            | ":(exclude,glob)" + .prefix + ".claude/skills/" + .name + "/**"
          else ":(exclude,literal)" + . end] | unique) as $excludes
    | if ($includes | length) > 0 then $includes[], $excludes[] else empty end
  ' "$1" 2>/dev/null || return 1
}

# Epoch second of the newest gaia-fitness close row on the usage ledger. Nothing
# (status 0) when the file is absent or holds no such row; a line that does not
# parse is skipped. 1 when the file exists but cannot be read, or grep or jq
# itself fails.
gaia_fitness_newest_close() {
  local ledger=$1 lines grep_status epoch
  [ -e "$ledger" ] || return 0
  [ -r "$ledger" ] || return 1
  lines="$(LC_ALL=C grep -F -- gaia-fitness "$ledger" 2>/dev/null)"
  grep_status=$?
  [ "$grep_status" -le 1 ] || return 1
  [ "$grep_status" -eq 0 ] || return 0
  epoch="$(printf '%s\n' "$lines" | jq -nR -r '
    [inputs
     | (try fromjson catch null)
     | select(type == "object" and .kind == "binding" and .type == "close"
              and .workflow == "gaia-fitness" and (.ts | type) == "string")
     | try (.ts | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch empty]
    | if length > 0 then max else empty end
  ' 2>/dev/null)" || return 1
  [ -z "$epoch" ] || printf '%s\n' "$epoch"
}

# The fitness_commit_threshold from a project config: a positive whole number,
# else the default. Always status 0.
gaia_fitness_commit_threshold() {
  local value
  value="$(jq -r '.fitness_commit_threshold | if type == "number" and . > 0 and . == floor then . else empty end' "$1" 2>/dev/null)" || value=""
  [ -n "$value" ] || value=$GAIA_FITNESS_DEFAULT_THRESHOLD
  printf '%s\n' "$value"
  return 0
}

# 0 when the commit subject starts with a prefix GAIA delivers.
gaia_fitness_is_gaia_subject() {
  local subject=$1 prefix
  for prefix in "${GAIA_FITNESS_GAIA_SUBJECT_PREFIXES[@]}"; do
    case "$subject" in
      "$prefix"*) return 0 ;;
    esac
  done
  return 1
}

# Count non-merge commits reachable from HEAD that touch a pathspec, committed
# strictly after <after-epoch> (whole history when empty), skipping GAIA-
# delivered subjects, stopping at <cap>. 1 on a git failure; 2 for a shallow
# repository (the count would be a lie).
gaia_fitness_count_commits() {
  local repo=$1 after=$2 cap=$3 shallow log committed subject count=0
  local -a since=()
  shift 3
  [ -z "$after" ] || case "$after" in *[!0-9]*) return 1 ;; esac
  case "$cap" in '' | *[!0-9]*) return 1 ;; esac
  shallow="$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" || return 1
  [ "$shallow" != true ] || return 2
  if [ "$#" -eq 0 ]; then
    printf '0\n'
    return 0
  fi
  [ -z "$after" ] || since=("--since=@$after")
  log="$(git -C "$repo" log HEAD --no-merges --format='%ct%x09%s' ${since[@]+"${since[@]}"} -- "$@" 2>/dev/null)" || return 1
  while IFS=$'\t' read -r committed subject; do
    [ -n "$committed" ] || continue
    [ "$count" -lt "$cap" ] || break
    if [ -n "$after" ] && [ "$committed" -le "$after" ]; then
      continue
    fi
    gaia_fitness_is_gaia_subject "$subject" && continue
    count=$((count + 1))
  done <<<"$log"
  printf '%s\n' "$count"
}

# 0 when main-version >= entry-version: numeric x.y.z core first, and on an
# equal core a release outranks a prerelease (two prereleases reach each other
# only when identical). 1 otherwise or when either does not parse.
gaia_fitness_version_reached() {
  local pattern='^v?([0-9]+)\.([0-9]+)\.([0-9]+)(-.+)?$'
  local main_major main_minor main_patch main_pre
  local entry_major entry_minor entry_patch entry_pre
  [[ $1 =~ $pattern ]] || return 1
  main_major=${BASH_REMATCH[1]} main_minor=${BASH_REMATCH[2]}
  main_patch=${BASH_REMATCH[3]} main_pre=${BASH_REMATCH[4]}
  [[ $2 =~ $pattern ]] || return 1
  entry_major=${BASH_REMATCH[1]} entry_minor=${BASH_REMATCH[2]}
  entry_patch=${BASH_REMATCH[3]} entry_pre=${BASH_REMATCH[4]}
  main_major=$((10#$main_major)) main_minor=$((10#$main_minor)) main_patch=$((10#$main_patch))
  entry_major=$((10#$entry_major)) entry_minor=$((10#$entry_minor)) entry_patch=$((10#$entry_patch))
  if [ "$main_major" -ne "$entry_major" ]; then
    [ "$main_major" -gt "$entry_major" ]
    return
  fi
  if [ "$main_minor" -ne "$entry_minor" ]; then
    [ "$main_minor" -gt "$entry_minor" ]
    return
  fi
  if [ "$main_patch" -ne "$entry_patch" ]; then
    [ "$main_patch" -gt "$entry_patch" ]
    return
  fi
  [ -z "$main_pre" ] || [ "$main_pre" = "$entry_pre" ]
}

# Blend signal: prints {"count":N,"landed":{...}}. <landed-json> is the previous
# `landed` map. An entry counts once main has reached its version, unless a
# close row newer than the version's landing stamp answered it. 1 when the
# record is malformed or <landed-json> is not an object.
gaia_fitness_blend_signal() {
  local record=$1 main_version=$2 close=$3 landed=$4 now=$5 version reached=""
  jq -e 'type == "object"' <<<"$landed" >/dev/null 2>&1 || return 1
  case "$now" in '' | *[!0-9]*) return 1 ;; esac
  case "$close" in *[!0-9]*) return 1 ;; esac
  if [ ! -e "$record" ]; then
    printf '{"count":0,"landed":{}}\n'
    return 0
  fi
  jq -e '
    type == "object" and .version == 1 and (.entries | type) == "array"
    and all(.entries[]; type == "object"
            and (.path | type) == "string" and (.version | type) == "string")
  ' "$record" >/dev/null 2>&1 || return 1
  while IFS= read -r version; do
    [ -n "$version" ] || continue
    if gaia_fitness_version_reached "$main_version" "$version"; then
      reached="$reached$version"$'\n'
    fi
  done <<<"$(jq -r '[.entries[].version] | unique[]' "$record")"
  jq -c --argjson landed "$landed" --argjson now "$now" \
    --arg close "$close" --arg reachedLines "$reached" '
    ($reachedLines | split("\n") | map(select(length > 0))) as $reached
    | . as $record
    | [.entries[] | select(.version as $v | $reached | index($v))] as $hit
    | ($landed + (reduce ($hit[].version) as $v ({};
        if ($landed | has($v)) then . else .[$v] = $now end))) as $stamps
    | {count: ($hit
               | map(select(($close | length) == 0
                            or (($close | tonumber) <= $stamps[.version]))
               ) | length),
       landed: ($stamps | with_entries(
         select(.key as $k | $record.entries | any(.version == $k))))}
  ' "$record"
}
