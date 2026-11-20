#!/usr/bin/env bash
# SC2034 is intentional file-wide: the string below is read by
# lint-git-path-quoting.sh, never here.
# shellcheck disable=SC2034
#
# The class detector of lint-git-path-quoting.sh. Sourced only by that script;
# assigns OWN_AWK and does no other work at source time.

# The detector prints one `file:line: message` per unquoted call.
#
# Four discriminations, each earning its place on a real line in this
# repository rather than on symmetry:
#
#   invoked  -- the text immediately before the call is a `git` invocation,
#               optionally carrying -C/-c options. Without it,
#               check-audit-base-derivation.sh's GAIA_AUDIT_DIFF_CALL is a hit:
#               the call is that variable's VALUE, not a command.
#   in-fence -- markdown only, and the whole of what makes a documentation page
#               scannable without making it noisy: a line is a candidate when a
#               fence delimiter has opened and none has closed it. Every other
#               line on the page is prose and is never read.
#   in-span  -- an odd number of backticks before the call on the line means it
#               sits inside a markdown code span, so it is prose. Without it,
#               the audit workflow's agent prompt is a hit, where a code span
#               instructs a model to run the command. It is switched off inside
#               a fence, where a code span cannot nest and an odd count is a
#               legacy substitution instead.
#   in-option-region
#            -- both halves accept `-z` as a standalone token anywhere in the
#               call's option region, and stop at the first token not beginning
#               with `-`, or at an explicit `--`. A fixed position would be
#               wrong for either: `ls-files` idiomatically carries selectors
#               first (`--others --exclude-standard -z`), and `diff` carries
#               `--cached` or `--staged` before `--name-only`. Terminating the
#               walk is what keeps the guarantee a fixed position was there to
#               give: a pathspec cannot vouch for the call, because the walk
#               never reaches one. `diff` is on the surface only when the walk
#               finds `--name-only` in that region, so a plain `git diff` and a
#               `git diff --quiet` are never candidates.
#
# Full-line comments are skipped outright, which covers both a shell comment and
# a `#` line inside a workflow `run:` block.
#
# Known blind spots, stated rather than discovered later, and split by which
# WAY they fail, because that is the part that matters: they are not all
# fail-closed, and treating them alike hides the ones that are not.
#
# The backtick boundary is stated as a RULE rather than as a list of shapes,
# deliberately. An enumeration of shapes is always one shape short, and each
# round of extending it invites the next; the rule below is closed, so it cannot
# be incomplete:
#
#   The command-position test recognizes a backtick opening immediately after
#   `=` or `(`, and NOTHING ELSE. Every other position is treated as a markdown
#   code span.
#
# Both of that rule's error directions follow from it and neither is a separate
# discovery:
#   - FAIL-OPEN: a backtick command substitution opening after anything else --
#     a quote, a pipe, a separator, or bare command position -- is missed. That
#     is a real miss, and closing it needs a shell tokenizer, which is more
#     machinery than this gate is worth.
#   - FAIL-CLOSED: parenthetical prose whose parenthesis is followed by a
#     backtick is flagged as an invocation. The repair is to reword the prose.
#
# The other boundaries, both FALSE POSITIVES, so both fail CLOSED. They demand
# `-z`, which is never wrong on a call whose output is parsed, so each costs a
# correct edit and never a missed defect:
#   - `-z` written on a line continuation after the call reads as missing. This
#     is not a `*.bats` question and it does not change with the widened
#     surface.
#   - A single-quoted string containing a literal `git diff --name-only` reads
#     as an invocation on `*.sh`, git hooks, workflow YAML and markdown, where
#     nothing distinguishes a string constant from executed shell. On `*.bats`
#     the same text, written through a recognized fixture-writing idiom, is
#     read as data instead; see
#     wiki/decisions/Shell Guard Fixture Discrimination.md for the convention.
#
# `*.bats` residuals, now that the surface reaches it:
#   - A fixture written through a helper outside guard-awk-lib.sh's recognized
#     set is read as executed shell rather than data, so it reds until the set
#     is extended or the line carries a suppression pragma.
#   - The suppression pragma is itself a residual on every OTHER surface: a
#     `gaia-lint-ignore lint-git-path-quoting: ...` comment above a line on any
#     scanned surface but `*.bats` waives nothing there. This
#     guard is the designated reader for the pragma, and reports that shape as
#     honored nowhere outside `*.bats` rather than treating it as a fix.
#
# Two further FALSE NEGATIVES, unrelated to backticks:
#   - A call assembled through a variable (`$GIT diff --name-only`), which is
#     equally tokenizer-bound.
#   - `--name-only` written AFTER a positional revision (`git diff HEAD
#     --name-only`, `git diff "$base...HEAD" --name-only`). The walk terminates
#     at the revision, because a revision is exactly what a non-option token
#     looks like, so the option region never reaches the flag and the call is
#     classified off-surface. This is a fail-OPEN miss of the gate's own class,
#     and it is the price of the termination rule: the same stop is what keeps
#     a pathspec from vouching for a call that quotes. Distinguishing a revision
#     from a pathspec needs git's own argument parser, not a scanner. Every call
#     in this tree writes its options first, which is the idiom the fix hints
#     advertise, so nothing here is missed today.
#
# Out of scope entirely: `-z` does not, on its own, survive a path containing a
# literal newline when the consumer re-splits on newlines via `tr`. That is a
# separate and far rarer class than the one this gate closes, and nothing here
# asserts otherwise.
# The class-detection program, concatenated after $GAIA_GUARD_AWK so it can call
# the shared fixture-versus-execution discriminator. Hoisted into a variable,
# unchanged character for character from its former inline form, because
# concatenation requires a variable rather than a literal awk argument.
# Single-quoted so every `$`, `$(` and awk field reference reaches awk as literal
# program text; the disable is targeted rather than file-wide, so a genuine
# SC2016 anywhere else here still fires.
# shellcheck disable=SC2016
readonly OWN_AWK='
    # option_walk(window): walk the option region following a call, setting
    # has_z when a standalone -z appears in it, has_name_only when --name-only
    # does, and existence_only when --error-unmatch does. All three are
    # deliberately global: awk has no other way to return a tuple. The walk
    # stops at the first token that is not an option, which is exactly where a
    # pathspec would begin, so a pathspec can never vouch for the call.
    function option_walk(window,   token_count, i, token, tokens) {
      has_z = 0
      has_name_only = 0
      existence_only = 0
      token_count = split(window, tokens, "[ \t]+")
      for (i = 1; i <= token_count; i++) {
        token = tokens[i]
        # Leading whitespace in the window yields an empty first field; it is
        # not a token, and skipping it must not terminate the walk.
        if (token == "") continue
        # Trailing shell punctuation is not part of the option. A substitution
        # that closes against its last option -- `$(git diff --cached
        # --name-only)`, `"$(git ls-files -z)"` -- yields `--name-only)` and
        # `-z)"`, which match no option the walk looks for and are not pathspecs
        # either, so without this the first is missed and the second is a false
        # positive on a compliant call. The double quote is in the class
        # BECAUSE the assigned-and-quoted form `x="$(...)"` is the common one,
        # and stripping every character except that one leaves the walk blind
        # to precisely the spelling most calls are written in. It cannot make a
        # quoted pathspec vouch for a call: `"-z"` still begins with a quote
        # after the strip, so it terminates the walk as a non-option. A literal
        # single quote is absent from the class because this awk program sits
        # inside a single-quoted shell string, and it is not needed: a command
        # substitution cannot close against one.
        sub(/[")`;|&]+$/, "", token)
        if (token == "--") break
        if (substr(token, 1, 1) != "-") break
        if (token == "-z") has_z = 1
        if (token == "--name-only") has_name_only = 1
        if (token == "--error-unmatch") existence_only = 1
      }
    }
    BEGIN {
      gaia_scan_reset()
      # callname is what is matched in the text; calllabel is what the report
      # names. They differ for `diff` because the surface is the call PLUS the
      # --name-only the walk finds in its option region, and only the walk can
      # see that: the text between the two is an open set of selectors.
      call_count = 2
      callname[1] = "diff";     calllabel[1] = "diff --name-only"
      callname[2] = "ls-files"; calllabel[2] = "ls-files"
    }
    # Pass 1 of a two-pass `*.bats` invocation accumulates the prepass sets a
    # fixture constant bound far above its consuming helper call needs; every
    # other surface is single-pass, so this rule never matches there.
    is_bats && NR == FNR { gaia_scan_prepass($0); next }
    # Ahead of every next below, so the pragma reader sees the full-line
    # comments the fence and comment-skip rules discard.
    { gaia_scan_feed($0, is_bats) }
    # Off-surface arm: a pragma naming this guard waives nothing
    # outside `*.bats`, so it is reported here regardless of whether its target
    # line also carries an instance, which the detector below may still print.
    !is_bats && gaia_scan_pragma_here("lint-git-path-quoting") {
      printf "%s:%d: gaia-lint-ignore is honored only in *.bats; this pragma waives nothing here\n", file, FNR
    }
    # A fence delimiter changes the state and is never itself scanned; the
    # opening line carries the info string (```bash), which is not a call.
    #
    # A bare toggle is wrong in two ways that both fail OPEN, and both land on
    # the executed-instruction pages this half exists for. It closes on the
    # opener of a NESTED block, so a ```bash inside a ````markdown wrapper
    # reads as prose from there to the outer close, and the page still balances
    # so no parity check can see it. And it never opens on a fence carrying a
    # blockquote prefix, which is how a page quotes a prompt an agent is told to
    # run verbatim. So the delimiter is remembered rather than counted: a closer
    # must be the same character and at least as long as the opener that is
    # open, the rule CommonMark itself uses, and the leading run may carry `>`.
    # No apostrophe anywhere in this block: it sits in a single-quoted string.
    is_markdown {
      if (match($0, /^[[:space:]>]*(```+|~~~+)/)) {
        delimiter = substr($0, RSTART, RLENGTH)
        sub(/^[[:space:]>]*/, "", delimiter)
        delimiter_character = substr(delimiter, 1, 1)
        delimiter_length = length(delimiter)
        # A closer carries no info string, which CommonMark requires and which
        # is the only thing separating a close from a nested open of the SAME
        # run length: inside a ```markdown block, a ```bash line is content.
        # Without this the scanner leaves the fence there and reads the nested
        # body as prose, and that page renders as one well-formed block, so
        # unlike an unbalanced page it never announces itself to its reader.
        tail = substr($0, RSTART + RLENGTH)
        if (!infence) { infence = 1; fence_character = delimiter_character; fence_length = delimiter_length }
        else if (delimiter_character == fence_character && delimiter_length >= fence_length && tail ~ /^[[:space:]]*$/) { infence = 0 }
        next
      }
    }
    # Outside a fence, markdown is prose in full: a paragraph naming a
    # path-listing command is documentation, not a call site, whether or not its
    # author wrapped it in a code span.
    is_markdown && !infence { next }
    /^[[:space:]]*#/ { next }
    {
      for (call_index = 1; call_index <= call_count; call_index++) {
      call = callname[call_index]
      label = calllabel[call_index]
      call_length = length(call)
      consumed = 0
      rest = $0
      while ((match_position = index(rest, call)) > 0) {
        absolute_match_position = consumed + match_position
        prefix = substr($0, 1, absolute_match_position - 1)
        window = substr($0, absolute_match_position + call_length)

        # Any leading git global option, not just -c/-C: `git --no-pager diff
        # --name-only` is as much an invocation as `git -C "$root" diff`, and a
        # selector naming two options by hand misses the rest of an open set.
        # An option token is anything starting with `-`; the optional following
        # token is the value form -c/-C take.
        invoked = (prefix ~ /(^|[^[:alnum:]_.-])git( +-[^ ]+( +[^- ][^ ]*)?)* +$/)

        ticks = gsub(/`/, "`", prefix)
        # Inside a fenced block the in-span test is not merely unnecessary, it is
        # wrong: a markdown code span cannot nest inside a fence, so an odd
        # backtick count there is a legacy command substitution or a literal
        # backtick in shell, never prose. Leaving the test on would hand every
        # fenced snippet a fail-open escape the shell surface does not have.
        inspan = (!infence && ticks % 2 == 1)
        # An odd backtick count alone cannot tell a markdown code span from a
        # LEGACY COMMAND SUBSTITUTION -- the two are textually identical, and
        # reading `changed=`git diff --name-only "$B"`` as prose is a fail-OPEN
        # miss rather than the fail-closed kind this scan is happy to make. A
        # backtick opening immediately after `=` or `(` is in command position,
        # so it is substitution rather than prose. Those two characters are the
        # whole rule, in both directions: every other opening position is missed
        # (fail-open) and parenthetical prose is flagged (fail-closed). The
        # blind-spot block above states that as a rule rather than enumerating
        # the shapes it produces.
        if (prefix ~ /[=(]`/) inspan = 0

        option_walk(window)
        if (call == "ls-files")
          quoted_ok = (has_z || existence_only)
        else
          # A `diff` with no --name-only in its option region is off the surface
          # entirely rather than a passing hit, so it can never be reported.
          quoted_ok = (!has_name_only || has_z)

        if (invoked && !inspan && !quoted_ok) {
          # In this order: a fixture-region line is data (skip), an honored
          # pragma is a deliberate waiver (suppressed), both inert when is_bats
          # is 0. The message deliberately does NOT put `git` in front of the
          # call name: with the binary name there, this very line matches the
          # detector and the gate flags its own diagnostic. Caught by running
          # the gate over its own tree, which is the cheapest possible proof
          # that the "invoked" discrimination works.
          if (!(is_bats && (gaia_scan_skip() || gaia_scan_suppressed("lint-git-path-quoting"))))
            printf "%s:%d: %s without -z: a C-quoted non-ASCII path stops matching in the consumer\n", file, FNR, label
        }
        consumed = absolute_match_position + call_length - 1
        rest = substr($0, consumed + 1)
      }
      }
    }
    END { gaia_scan_end(file, is_bats, "lint-git-path-quoting", 1, 1) }
'
