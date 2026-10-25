# shellcheck shell=bash
#
# Right side of the GAIA statusline: the GAIA nudges, read from the TTL-cached
# refresher and fitted to the statusline row (COLUMNS less Claude Code's
# built-in spacing, see gaia_statusline_measure_left). Unlike the left side,
# which a developer's own global statusLine.command can replace, the right side
# always renders. Sourced by gaia-statusline.sh as
# "$GAIA_DIRECTORY/statusline/gaia-statusline-right.sh"; defines its functions
# and runs nothing at source time.
#
# Each nudge has its own Large, Medium and Small form, then an icon, then a
# `+N` for however many still do not fit; the lowest-priority nudge still at
# its current size shrinks first, so a higher-priority nudge is never at a
# later size step than a lower-priority one (a nudge with no Medium form, such
# as /gaia-cleanse, shows its Small text at that step).
#
# In linked worktrees: the one blocking, per-clone nudge (`/setup-gaia`) still
# renders from every tree, so the statusline does not go dark. The rest of the
# right side is a task queue for the main checkout, and a linked worktree
# cannot act on any of it, so it is gated out there. Every segment still reads
# SHARED state -- the update-check cache, the debt count and the setup marker
# are all scope "shared" in `.gaia/state-registry.json`, one physical copy
# under the main checkout's `.gaia/local` -- which is exactly why the setup
# nudge is correct from a worktree: the answer it reads is main's answer.
# A flow that genuinely must run on the main checkout refuses out loud when it
# is invoked, which is where the harder guarantee belongs.

# Sets columns and left_visible in the caller's scope from the caller's
# `left`; called only where a right side is about to be composed (the
# setup-gaia branch and the nudges-present branch), so a render with no right
# side pays no pipeline for it. `awk`'s END block reports the LAST line's
# length (the row the right side actually joins) rather than one number per
# line, and `column_count+0` forces a plain digit even on empty input.
#
# `LC_ALL=C` makes every awk (BWK, gawk, mawk) count bytes rather than
# characters, even under a UTF-8 locale where BSD awk otherwise miscounts a
# multi-byte glyph as more than one column and gawk raises an invalid-range
# error on the byte-range gsub below. Deleting every UTF-8 continuation byte
# (`\200`-`\277`) first leaves exactly one byte per character; a 4-byte lead
# byte (`\360`-`\364`, emoji and other astral-plane glyphs) is counted a
# second time (`wide_glyph_count`) to match its 2-column render. Known limit: a 3-byte
# glyph (CJK) still counts one column but renders two.
#
# `columns` is the statusline row's usable width, not COLUMNS. Claude Code sets
# COLUMNS to the full terminal width, but draws the statusline inside built-in
# spacing of 2 columns on each side, and cuts a longer line to fit with a
# trailing `…`. Measured with a ruler exactly COLUMNS wide at COLUMNS 189, 153
# and 100: each time the last column before the `…` was COLUMNS - 5, so the row
# holds COLUMNS - 4. Known limit: a user-set `statusLine.padding` narrows the
# row further and is not read here.
STATUSLINE_BUILT_IN_SPACING=4
gaia_statusline_measure_left() {
  columns=$(( ${COLUMNS:-120} - STATUSLINE_BUILT_IN_SPACING ))
  left_visible=$(printf '%b' "$left" | sed 's/\x1b\[[0-9;]*m//g' | LC_ALL=C awk '{wide_glyph_count = gsub(/[\360-\364]/, "&"); gsub(/[\200-\277]/, ""); column_count = length + wide_glyph_count} END {print column_count+0}')
  case "$left_visible" in
    ''|*[!0-9]*) left_visible=0 ;;
  esac
}

# gaia_statusline_right <gaia-directory> <state-root> <is-worktree> <left>
# Sets _GAIA_STATUSLINE_RIGHT to the rendered string (ANSI escapes included)
# and _GAIA_STATUSLINE_RIGHT_PADDING to the spaces that right-align it after
# <left>; returns 1 and leaves both empty when there is nothing to show.
gaia_statusline_right() {
  local gaia_directory="${1:-}" state_root="${2:-}" is_worktree="${3:-}" left="${4:-}"
  local cache_file="$state_root/.gaia/local/cache/shared/update-check.json"
  local debt_cache="$state_root/.gaia/local/debt/count.json"
  local right="" right_width=0 columns=0 left_visible=0 padding
  local mid_init setup_complete setup_pending_count setup_read setup_completed_at setup_project_arguments setup_text
  local SETUP_STATE_FILE SETUP_FEATURES_FILE SETUP_PROJECT_FILE GAIA_SETUP_OWED_JQ
  local nudge_color nudge_small nudge_large nudge_mid nudge_icon nudge_floor setup_noun full
  local local_version cache_fields outdated_count security_count update_state update_version update_login
  local codify_count has_codify_reason codify_reason cleanse_nudge cleanse_reason
  local codify_unclassified residue_count wiki_drift_count codify_mid deps_outdated deps_security
  local fallback_reason codify_noun
  local fitness_grade fitness_blend_count fitness_commit_count fitness_commit_threshold fitness_large fitness_mid
  local RESIDUE_NUDGE_THRESHOLD residue_suffix WIKI_NUDGE_THRESHOLD debt_count debt_noun
  local dense_color dense_small dense_large dense_mid dense_icon dense_floor dense_iconcount slot nudge_count
  local available_width nudge_size i hidden_count shrink_step shrink_target shrink_size
  _GAIA_STATUSLINE_RIGHT=""
  _GAIA_STATUSLINE_RIGHT_PADDING=""

  # ---------- Right side from cache ----------
  # Per-clone setup gate: when .gaia/local/setup-state.json is missing or its
  # completed_at is null, the right side shows ONLY `/setup-gaia`; the other
  # indicators are suppressed until the developer has run through the per-clone
  # setup at least once. The setup file is gitignored and shared across the
  # clone's trees, so an unset-up clone reads as unset-up from every one of them
  # -- which is correct: it is a blocking condition wherever the session sits.
  #
  # Exception: when .claude/commands/gaia-init.md exists, this is a fresh
  # create-gaia project mid-init. /setup-gaia is not applicable until
  # /gaia-init finishes (which deletes that file). Suppress all right-side
  # indicators during that window.
  mid_init=0
  if [ -f "$state_root/.claude/commands/gaia-init.md" ]; then
    mid_init=1
  fi
  # gaia:maintainer-only:start
  # Except in GAIA's own source repo, where that command file is a tracked
  # product artifact: it ships to adopters, so it always exists here and
  # /gaia-init never runs to delete it. Without the exception below, the gate
  # above suppresses this repo's right side permanently and the maintainer sees
  # none of their own nudges.
  #
  # The discriminator is `.gaia/cli/src`, the CLI's TypeScript source. It is
  # release-excluded, so no adopter machine has it, mid-init or otherwise, which
  # is what makes its presence mean "this repo is GAIA itself".
  # Tracked-ness cannot serve: create-gaia commits the whole
  # scaffold before it launches /gaia-init, so the command file is tracked
  # mid-init too.
  #
  # Anchored on the state root like the gate file above it, so the question it asks
  # is "is the MAIN checkout the source repo", which is the same answer from
  # every linked worktree.
  #
  # The release tarball strips this block, so an adopter's copy carries the plain
  # gate above and nothing else.
  if [ -d "$state_root/.gaia/cli/src" ]; then
    mid_init=0
  fi
  # gaia:maintainer-only:end
  if [ "$mid_init" -eq 1 ]; then
    : # /gaia-init in progress, no right-side indicators
  else
    SETUP_STATE_FILE="$state_root/.gaia/local/setup-state.json"
    SETUP_FEATURES_FILE="$state_root/.gaia/setup-features.json"
    setup_complete="false"
    setup_pending_count=0
    if [ -f "$SETUP_STATE_FILE" ]; then
      if command -v jq >/dev/null 2>&1; then
        # The pending setup choices ride the completion read, so a render spawns
        # one jq whether or not the list exists: the undecided machine-scope ids
        # plus the project-scope ids this machine can act on (setup-owed.sh,
        # shared with /setup-gaia's closing message). The list and the project
        # config go in as raw strings and are parsed under try, so a malformed
        # file yields a zero count and never fails the completion read it shares
        # a process with. Count first, then completed_at: the count never holds
        # a comma.
        if [ -f "$SETUP_FEATURES_FILE" ]; then
          # shellcheck disable=SC2016 # jq variables, expanded by jq.
          GAIA_SETUP_OWED_JQ='def gaia_setup_owed($list_text; $project_text): [];'
          # shellcheck source=/dev/null
          . "$gaia_directory/statusline/setup-owed.sh" 2>/dev/null || true
          SETUP_PROJECT_FILE="$state_root/.gaia/project.json"
          if [ -f "$SETUP_PROJECT_FILE" ]; then
            setup_project_arguments=(--rawfile project "$SETUP_PROJECT_FILE")
          else
            setup_project_arguments=(--arg project "")
          fi
          setup_read=$(jq -r --rawfile list "$SETUP_FEATURES_FILE" "${setup_project_arguments[@]}" "$GAIA_SETUP_OWED_JQ"'
            (.decisions | if type == "object" then . else {} end) as $decisions
            | [ ((try ([$list | fromjson | .features | arrays | .[] | objects
                        | select((.scope == "machine") and ((.id | type) == "string")
                                 and (($decisions[.id] // "") | IN("applied", "declined", "not-applicable") | not))]
                       | length) catch 0)
                 + (try (gaia_setup_owed($list; $project) | length) catch 0)
                 | tostring),
                (.completed_at // "null") ]
            | join(",")' "$SETUP_STATE_FILE" 2>/dev/null)
          setup_pending_count="${setup_read%%,*}"
          setup_completed_at="${setup_read#*,}"
        else
          setup_completed_at=$(jq -r '.completed_at // "null"' "$SETUP_STATE_FILE" 2>/dev/null)
        fi
        if [ "$setup_completed_at" != "null" ]; then
          setup_complete="true"
        fi
        case "$setup_pending_count" in
          ''|*[!0-9]*) setup_pending_count=0 ;;
        esac
      else
        # No jq: completion still reads from the file, but the pending count is
        # skipped, so the post-completion nudge stays dark rather than erroring.
        # Fallback: a complete state has a non-null completed_at value.
        if grep -q '"completed_at"[[:space:]]*:[[:space:]]*"' "$SETUP_STATE_FILE" 2>/dev/null; then
          setup_complete="true"
        fi
      fi
    fi
    # gaia:maintainer-only:start
    # GAIA's own source repo never runs /setup-gaia, so neither setup segment
    # below applies here: its setup state, when it has one, records no choices,
    # and a fresh clone has none at all. Treat setup as complete with nothing
    # pending. Same `.gaia/cli/src` discriminator as the mid-init exception
    # above, and the release tarball strips this block the same way.
    if [ -d "$state_root/.gaia/cli/src" ]; then
      setup_complete="true"
      setup_pending_count=0
    fi
    # gaia:maintainer-only:end

    if [ "$setup_complete" != "true" ]; then
      gaia_statusline_measure_left
      setup_text='/setup-gaia (Required)'
      right=$'\033[01;95m''⚙️ '"$setup_text"$'\033[00m'
      # The icon is counted as 2 columns, the same as every nudge's icon below.
      right_width=$((3 + ${#setup_text}))
    elif [ "$is_worktree" = "true" ]; then
      : # linked worktree, setup complete: the rest is a main-checkout task
        # queue, nothing to build; right stays empty and the caller prints the
        # left side alone.
    else
      # Nudge slots, indexed by render priority rather than by where each one
      # is armed below: setup-gaia 0, update-gaia 1, update-deps 3, gaia-cleanse 4,
      # gaia-fitness 5, gaia-codify 6, gaia-debt 7, gaia-residue 8, gaia-wiki 9;
      # slot 2 is free. The update-check-derived nudges stay gated on $cache_file;
      # the setup nudge and the debt nudge are gated independently (on the setup
      # read above and on $debt_cache) so they still render when update-check.json
      # is absent, which is why debt (7) is armed after residue (8) in source
      # order but renders before it.
      #
      # Each slot carries its Large text, its bare Small command, and `mid`,
      # the Medium form's parenthetical content; an empty mid means the nudge
      # has no Medium size (its Large shrinks straight to Small). The renderer
      # below reads every slot once both blocks have run, sizes each nudge
      # independently (Large, then Medium, then Small, then icon, then folded
      # into the trailing `+N`), and shows an icon's mid as its count only when
      # mid is all digits.
      #
      # A slot may also carry a floor (empty means none; 1 means Medium): the
      # smallest size the shrink loop will take that nudge down to. Its mid text
      # is what names who the nudge is about, so it never shrinks past the form
      # that still shows it; the loop keeps shrinking and hiding every other
      # nudge, and when the line still does not fit it renders past the
      # available width with the `+N`.
      #
      # Each slot's SGR color, and the setup segment's, follows the color table
      # in wiki/concepts/Claude Skills.md (Statusline update indicators): a new
      # nudge takes its color by that page's rule, not by eye.
      nudge_color=()
      nudge_small=()
      nudge_large=()
      nudge_mid=()
      nudge_icon=()
      nudge_floor=()
      nudge_set() {
        nudge_color[$1]="$2"
        nudge_small[$1]="$3"
        nudge_large[$1]="$4"
        nudge_mid[$1]="$5"
        nudge_icon[$1]="$6"
        nudge_floor[$1]="${7:-}"
      }
      # Post-completion setup nudge: machine-scope setup choices the shipped list
      # holds and this machine has not decided, plus the owed project-scope ones
      # this machine can act on (setup-owed.sh). Highest priority because it is
      # the only nudge that tells a teammate who pulled a release about a choice
      # only they can make.
      if [ "$setup_pending_count" -gt 0 ] 2>/dev/null; then
        setup_noun="choices"
        [ "$setup_pending_count" -eq 1 ] && setup_noun="choice"
        printf -v full '/setup-gaia (%d %s pending)' "$setup_pending_count" "$setup_noun"
        nudge_set 0 '01;95' '/setup-gaia' "$full" "$setup_pending_count" '⚙️'
      fi
      if [ -f "$cache_file" ] && command -v jq >/dev/null 2>&1; then
        # One jq call reads every cache field this block uses, joined by a control
        # character no value contains; each value has control bytes stripped
        # (escape sequences, newlines, the delimiter itself) before it reaches a
        # terminal, since codify-tally's finding_class segments and the review
        # snapshot behind the cached reasons originate in PR text any author
        # controls. securityCount is never defaulted to 0: null (no advisory
        # source answered) must stay distinguishable from a real zero, so an
        # unreadable value yields an empty field. A cache written before
        # codifyNudgeReason existed has no key, which the has_codify_reason flag
        # carries. Silent on jq failure: every field then reads empty.
        #
        # The update nudge's state resolves in this same call: one ordered chain
        # of conditions yields the state, version and login fields, first match
        # wins (the checkout is behind origin, then a teammate's live update
        # claim, then the reader's own, then a plain available update). A claim whose tag or login falls outside the
        # sets the claim writer validates against is ignored rather than
        # stripped, and \A..\z anchor the whole value because ^ and $ match at
        # line breaks in jq. A cache without the claim fields resolves to the
        # plain update state.
        #
        # The pull state sits above all of them: origin's default branch carries a
        # higher version than the checkout's own version file, which is read live
        # with a shell builtin and passed in. Only the numeric core orders two
        # versions, and a local value or origin value that is not a version never
        # yields pull.
        local_version=""
        [ -r "$state_root/.gaia/VERSION" ] && { read -r local_version <"$state_root/.gaia/VERSION" || true; }
        local_version="${local_version%"${local_version##*[![:space:]]}"}"
        cache_fields=$(jq -r --arg local "$local_version" '
          def clean: tostring | gsub("[\u0000-\u001f\u007f]"; "");
          def version_core: if type == "string" then (capture("\\A(?<a>[0-9]+)\\.(?<b>[0-9]+)\\.(?<c>[0-9]+)(-[0-9A-Za-z.-]+)?\\z") | [(.a | tonumber), (.b | tonumber), (.c | tonumber)]) else null end;
          def valid_login: type == "string" and length <= 39 and test("\\A[A-Za-z0-9](-?[A-Za-z0-9])*\\z");
          def valid_tag: type == "string" and test("\\Av[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?\\z");
          (($local | version_core) // null) as $local_core
          | ((.gaiaOriginVersion | version_core) // null) as $origin_core
          | (if (.ghLogin | valid_login) then .ghLogin else "" end) as $me
          | ((if (.gaiaUpdateClaims | type) == "array" then .gaiaUpdateClaims else [] end)
              | map(select(type == "object" and (.number | type) == "number"
                           and (.tag | valid_tag) and (.authorLogin | valid_login)))
              | sort_by(.number)) as $claims
          | ([$claims[] | select(.authorLogin != $me)][0]) as $teammate
          | ([$claims[] | select(.authorLogin == $me)][0]) as $own
          | (if $local_core != null and $origin_core != null and $origin_core > $local_core then ["pull", .gaiaOriginVersion, ""]
             elif $me != "" and $teammate != null then ["progress", ($teammate.tag | .[1:]), $teammate.authorLogin]
             elif $me != "" and $own != null then ["resume", ($own.tag | .[1:]), ""]
             elif ((.gaiaHasUpdate // false | tostring) == "true") and ((.gaiaLatest // "" | clean) != "")
               then ["update", (.gaiaLatest | clean), ""]
             else ["", "", ""] end) as $state
          | [ (.outdatedCount // 0 | clean),
            (.securityCount | if type == "number" then (floor | tostring) else "" end),
            $state[0], $state[1], $state[2],
            ((.codifyCandidateCount // 0) | if type == "number" then (floor | tostring) else "0" end),
            (if has("codifyNudgeReason") then "1" else "0" end),
            ((.codifyNudgeReason // "") | clean),
            (.cleanseNudge // false | clean),
            (.cleanseNudgeReason // "" | clean),
            (.codifyUnclassifiedCount // 0 | clean),
            (.residueCandidateCount // 0 | clean),
            (.wikiDriftCount // 0 | clean),
            (.fitnessGrade // "" | clean),
            (.fitnessBlendCount | if type == "number" then (floor | tostring) else "" end | clean),
            (.fitnessCommitCount | if type == "number" then (floor | tostring) else "" end | clean),
            (.fitnessCommitThreshold | if type == "number" then (floor | tostring) else "" end | clean) ]
          | join("\u001f")' "$cache_file" 2>/dev/null) || cache_fields=""
        IFS=$'\037' read -r outdated_count security_count update_state update_version update_login \
          codify_count has_codify_reason codify_reason cleanse_nudge cleanse_reason \
          codify_unclassified residue_count wiki_drift_count \
          fitness_grade fitness_blend_count fitness_commit_count fitness_commit_threshold <<<"$cache_fields"
        case "$security_count" in
          ''|*[!0-9]*) security_count="" ;;
        esac
        case "$codify_count" in
          ''|*[!0-9]*) codify_count=0 ;;
        esac
        # The Medium/icon form for /gaia-codify; empty when there is no
        # candidate count, so the segment goes straight to Small.
        codify_mid=""
        [ "$codify_count" -gt 0 ] 2>/dev/null && codify_mid="$codify_count"

        case "$update_state" in
          pull)
            nudge_set 1 '01;36' '/update-gaia' "/update-gaia (pull $update_version)" "pull $update_version" '🚀'
            ;;
          progress)
            # A teammate holds the update, so there is nothing for this person to
            # run: no command, and the floor keeps the version and who is on it
            # visible at every width.
            nudge_set 1 '01;93' "GAIA $update_version" "GAIA $update_version in progress (@$update_login)" "@$update_login" '⌛️' 1
            ;;
          resume)
            nudge_set 1 '01;36' '/update-gaia' "/update-gaia (resume $update_version)" "resume $update_version" '🚀'
            ;;
          update)
            # No Medium: the Large reason is already just the version.
            nudge_set 1 '01;36' '/update-gaia' "/update-gaia ($update_version)" '' '🚀'
            ;;
        esac
        deps_outdated=0
        deps_security=0
        [ -n "$outdated_count" ] && [ "$outdated_count" -gt 0 ] 2>/dev/null && deps_outdated="$outdated_count"
        [ -n "$security_count" ] && [ "$security_count" -gt 0 ] 2>/dev/null && deps_security="$security_count"
        if [ "$deps_outdated" -gt 0 ] || [ "$deps_security" -gt 0 ]; then
          if [ "$deps_outdated" -gt 0 ] && [ "$deps_security" -gt 0 ]; then
            printf -v full '/update-deps (%d outdated, %d security)' "$deps_outdated" "$deps_security"
          elif [ "$deps_outdated" -gt 0 ]; then
            printf -v full '/update-deps (%d outdated)' "$deps_outdated"
          else
            printf -v full '/update-deps (%d security)' "$deps_security"
          fi
          nudge_set 3 '01;33' '/update-deps' "$full" "$((deps_outdated + deps_security))" '📦'
        fi
        # Both signals are discharged by the same bare `/gaia-codify` run, and no
        # argument selects between them, so they stack into one segment's reason
        # parameter rather than into a second segment naming the same command.
        # Same shape as the /gaia-cleanse segment below, which folds its reason in
        # the same way. This reads the refresher's own cached composition only:
        # it never reads the review snapshot itself. A cache written before
        # codifyNudgeReason existed has no key to read, so it falls back to
        # composing today's count text the same way the refresher's own
        # upgrade-window seed does.
        if [ "$has_codify_reason" = "1" ]; then
          if [ -n "$codify_reason" ]; then
            printf -v full '/gaia-codify (%s)' "$codify_reason"
            nudge_set 6 '01;35' '/gaia-codify' "$full" "$codify_mid" '🔨'
          fi
        else
          fallback_reason=""
          if [ "$codify_count" -gt 0 ] 2>/dev/null; then
            codify_noun="recurring patterns"
            [ "$codify_count" -eq 1 ] && codify_noun="recurring pattern"
            fallback_reason=$(printf '%d %s' "$codify_count" "$codify_noun")
          fi
          if [ -n "$codify_unclassified" ] && [ "$codify_unclassified" -gt 0 ] 2>/dev/null; then
            [ -n "$fallback_reason" ] && fallback_reason="${fallback_reason}, "
            fallback_reason=$(printf '%s%d unclassified' "$fallback_reason" "$codify_unclassified")
          fi
          if [ -n "$fallback_reason" ]; then
            printf -v full '/gaia-codify (%s)' "$fallback_reason"
            nudge_set 6 '01;35' '/gaia-codify' "$full" "$codify_mid" '🔨'
          fi
        fi
        if [ "$cleanse_nudge" = "true" ]; then
          if [ -n "$cleanse_reason" ]; then
            printf -v full '/gaia-cleanse (%s)' "$cleanse_reason"
            nudge_set 4 '01;32' '/gaia-cleanse' "$full" '' '🔎'
          else
            nudge_set 4 '01;32' '/gaia-cleanse' '/gaia-cleanse' '' '🔎'
          fi
        fi
        # Fitness nudge: arms on the first true of a cached grade, a positive
        # blended-file count, or a harness-commit count at or past the cached
        # threshold (15 when the cache holds none usable). Reads only the
        # fields the refresher cached.
        fitness_large=""
        fitness_mid=""
        case "$fitness_grade" in
          'A+'|A|A-|'B+'|B|B-|'C+'|C|C-|'D+'|D|D-|F)
            fitness_large="/gaia-fitness (grade $fitness_grade)"
            fitness_mid="$fitness_grade"
            ;;
        esac
        case "$fitness_blend_count" in
          ''|*[!0-9]*) fitness_blend_count=0 ;;
        esac
        case "$fitness_commit_count" in
          ''|*[!0-9]*) fitness_commit_count=0 ;;
        esac
        case "$fitness_commit_threshold" in
          ''|*[!0-9]*) fitness_commit_threshold=15 ;;
        esac
        [ "$((10#$fitness_commit_threshold))" -ge 1 ] || fitness_commit_threshold=15
        if [ -z "$fitness_large" ] && [ "$((10#$fitness_blend_count))" -gt 0 ]; then
          if [ "$((10#$fitness_blend_count))" -eq 1 ]; then
            fitness_large="/gaia-fitness (1 blended file)"
          else
            fitness_large="/gaia-fitness ($((10#$fitness_blend_count)) blended files)"
          fi
          fitness_mid="$((10#$fitness_blend_count))"
        fi
        if [ -z "$fitness_large" ] && [ "$((10#$fitness_commit_count))" -gt 0 ] \
          && [ "$((10#$fitness_commit_count))" -ge "$((10#$fitness_commit_threshold))" ]; then
          if [ "$((10#$fitness_commit_count))" -eq 1 ]; then
            fitness_large="/gaia-fitness (1 harness commit)"
          else
            fitness_large="/gaia-fitness ($((10#$fitness_commit_count)) harness commits)"
          fi
          fitness_mid="$((10#$fitness_commit_count))"
        fi
        if [ -n "$fitness_large" ]; then
          nudge_set 5 '01;94' '/gaia-fitness' "$fitness_large" "$fitness_mid" '💪'
        fi
        # Residue nudge: renders once at least RESIDUE_NUDGE_THRESHOLD keyed
        # candidates have aged past 30 days (the age dial lives in the tally,
        # computed pre-cap over the full post-suppression population) and
        # clears once the count falls back below it. Both dials are calibrated
        # against a corpus younger than one quarter and are re-measured after
        # two.
        RESIDUE_NUDGE_THRESHOLD=5
        case "$residue_count" in
          ''|*[!0-9]*) residue_count=0 ;;
        esac
        if [ "$residue_count" -ge "$RESIDUE_NUDGE_THRESHOLD" ] 2>/dev/null; then
          residue_suffix="s"
          [ "$residue_count" -eq 1 ] && residue_suffix=""
          printf -v full '/gaia-residue (%d residual%s)' "$residue_count" "$residue_suffix"
          nudge_set 8 '01' '/gaia-residue' "$full" "$residue_count" '🧹'
        fi
        # Wiki nudge: renders once the wiki trails HEAD by at least
        # WIKI_NUDGE_THRESHOLD non-bookkeeping commits. A maintainer constant,
        # deliberately not adopter-configurable. Reads only the count the
        # refresher cached; no repository query runs on this render path.
        WIKI_NUDGE_THRESHOLD=20
        case "$wiki_drift_count" in
          ''|*[!0-9]*) wiki_drift_count=0 ;;
        esac
        if [ "$wiki_drift_count" -ge "$WIKI_NUDGE_THRESHOLD" ] 2>/dev/null; then
          nudge_set 9 '01;96' '/gaia-wiki' "/gaia-wiki ($wiki_drift_count commits)" "$wiki_drift_count" '🧠'
        fi
      fi
      # Debt-backlog nudge, read from the pinned debt cache. Independent of
      # update-check.json so it renders whenever an open tech-debt count exists.
      if [ -f "$debt_cache" ] && command -v jq >/dev/null 2>&1; then
        debt_count=$(jq -r '.openCount // 0' "$debt_cache" 2>/dev/null)
        if [ -n "$debt_count" ] && [ "$debt_count" -gt 0 ] 2>/dev/null; then
          debt_noun="issues"
          [ "$debt_count" -eq 1 ] && debt_noun="issue"
          printf -v full '/gaia-debt (%d %s)' "$debt_count" "$debt_noun"
          nudge_set 7 '01;91' '/gaia-debt' "$full" "$debt_count" '🐛'
        fi
      fi

      # Compact the sparse priority slots into dense, priority-ordered arrays;
      # a gap between slots is a nudge that did not arm this render. `${!arr[@]}`
      # walks an indexed array's set keys in ascending order, which is what
      # makes the slot numbers double as the render order. dense_iconcount is
      # derived in the same pass: a nudge's mid is shown on its icon only when
      # it is all digits.
      dense_color=()
      dense_small=()
      dense_large=()
      dense_mid=()
      dense_icon=()
      dense_floor=()
      dense_iconcount=()
      for slot in "${!nudge_small[@]}"; do
        dense_color+=("${nudge_color[$slot]}")
        dense_small+=("${nudge_small[$slot]}")
        dense_large+=("${nudge_large[$slot]}")
        dense_mid+=("${nudge_mid[$slot]}")
        dense_icon+=("${nudge_icon[$slot]}")
        dense_floor+=("${nudge_floor[$slot]:-}")
        case "${nudge_mid[$slot]}" in
          ''|*[!0-9]*) dense_iconcount+=("") ;;
          *) dense_iconcount+=("${nudge_mid[$slot]}") ;;
        esac
      done
      nudge_count="${#dense_small[@]}"

      if [ "$nudge_count" -gt 0 ]; then
        gaia_statusline_measure_left
        # available_width reserves the 2-column minimum gap Compose keeps between the
        # two sides.
        available_width=$((columns - left_visible - 2))

        # Per-nudge size: 0 Large, 1 Medium, 2 Small, 3 icon, 4 hidden (folded
        # into the trailing `+N`). All start Large.
        nudge_size=()
        for ((i = 0; i < nudge_count; i++)); do
          nudge_size[i]=0
        done

        # Sets right_width, hidden_count, and right (composed inline, since
        # only the last call before the shrink loop below breaks is ever
        # printed) from the current $nudge_size values. Visible segments are
        # divided by ` │ `, and the trailing `+N` sits 1 column from its
        # neighbor. Every form leads with the nudge's emoji, so the icon form
        # is the one the text forms already taught; whatever follows sits 1
        # column from it, since flush the glyphs crowd together at statusline
        # font sizes. The emoji's width is hardcoded at 2 and only the ASCII
        # body after it is measured: `${#...}` counts an emoji as one
        # character in a UTF-8 locale, as several bytes in the C locale, and
        # counts a trailing U+FE0F presentation selector (⚙️) as another.
        measure() {
          right_width=0
          hidden_count=0
          right=""
          local i text_length text body icon_form last=-1
          for ((i = 0; i < nudge_count; i++)); do
            if [ "${nudge_size[$i]}" -eq 4 ]; then
              hidden_count=$((hidden_count + 1))
              continue
            fi
            case "${nudge_size[$i]}" in
              0) body="${dense_large[$i]}"; icon_form=0 ;;
              1)
                if [ -n "${dense_mid[$i]}" ]; then
                  body="${dense_small[$i]} (${dense_mid[$i]})"
                else
                  body="${dense_small[$i]}"
                fi
                icon_form=0
                ;;
              2) body="${dense_small[$i]}"; icon_form=0 ;;
              3) body="${dense_iconcount[$i]}"; icon_form=1 ;;
            esac
            if [ -n "$body" ]; then
              text="${dense_icon[$i]} ${body}"
              text_length=$((3 + ${#body}))
            else
              text="${dense_icon[$i]}"
              text_length=2
            fi
            if [ "$last" -ge 0 ]; then
              right_width=$((right_width + 3))
              right="${right} │ "
            fi
            right_width=$((right_width + text_length))
            if [ "$icon_form" -eq 1 ]; then
              right="${right}${text}"
            else
              right="${right}"$'\033['"${dense_color[$i]}"'m'"${text}"$'\033[00m'
            fi
            last=$i
          done
          if [ "$hidden_count" -gt 0 ]; then
            if [ "$last" -ge 0 ]; then
              right_width=$((right_width + 1))
              right="${right} "
            fi
            right_width=$((right_width + 1 + ${#hidden_count}))
            right="${right}+${hidden_count}"
          fi
        }

        # Shrink the lowest-priority nudge still at the current size, one step
        # at a time: every nudge to Medium bottom-up, then Medium to Small
        # bottom-up, then Small to icon bottom-up, then icon to hidden
        # bottom-up. A nudge with a floor skips any step past it but the step
        # still counts, so the others keep shrinking. shrink_step caps at
        # 4 * nudge_count (every nudge through every step), the point at which
        # every nudge that can be is hidden and the rest render with `+N`, even
        # past available_width, rather than emitting nothing. The measure() call
        # right before the break leaves `right` and `right_width` set to what
        # gets printed.
        shrink_step=0
        while :; do
          measure
          if [ "$right_width" -le "$available_width" ] || [ "$shrink_step" -ge $((4 * nudge_count)) ]; then
            break
          fi
          shrink_target=$((nudge_count - 1 - shrink_step % nudge_count))
          shrink_size=$((shrink_step / nudge_count + 1))
          if [ -z "${dense_floor[$shrink_target]}" ] || [ "$shrink_size" -le "${dense_floor[$shrink_target]}" ]; then
            nudge_size[shrink_target]=$shrink_size
          fi
          shrink_step=$((shrink_step + 1))
        done
      fi
    fi
  fi

  [ -n "$right" ] || return 1
  padding=$((columns - left_visible - right_width))
  [ "$padding" -lt 2 ] && padding=2
  _GAIA_STATUSLINE_RIGHT="$right"
  _GAIA_STATUSLINE_RIGHT_PADDING="$padding"
}
