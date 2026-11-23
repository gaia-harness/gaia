#!/usr/bin/env bats
# Tests for .claude/hooks/lib/message-heredoc.sh, exercised by sourcing it
# directly. The read guard's own suite (block-sensitive-read.bats) covers what
# the hook decides once the view is built; this one covers which shapes the
# view masks.
#
# Each row is `mask|<payload>` or `keep|<payload>`, the payload written with
# printf escapes so it carries real newlines and tabs. `mask` asserts the body
# is overwritten and the view keeps the text's length; `keep` asserts the view
# is the text unchanged. Each `keep` row departs from a `mask` row on the
# condition it pins.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$THIS_DIRECTORY/../../.." && pwd)"
  LIBRARY_FILE="$REPO_ROOT/.claude/hooks/lib/message-heredoc.sh"
  [ -f "$LIBRARY_FILE" ]
  # shellcheck source=.claude/hooks/lib/message-heredoc.sh disable=SC1091
  . "$LIBRARY_FILE"
}

# check_rows <row>...: run every row, report each one that fails, and fail if
# any did, so one run names every broken row rather than the first.
check_rows() {
  local row expectation text failures=0 newline=$'\n'
  for row in "$@"; do
    expectation=${row%%|*}
    # shellcheck disable=SC2059 # the row is a printf format by design, so its escapes become newlines
    text=$(printf "${row#*|}")
    GAIA_MESSAGE_HEREDOC_VIEW="not assigned"
    gaia_message_heredoc_view "$text"
    if [ "$expectation" = mask ]; then
      if [ "$GAIA_MESSAGE_HEREDOC_VIEW" = "$text" ] \
        || [ "${#GAIA_MESSAGE_HEREDOC_VIEW}" -ne "${#text}" ] \
        || [[ "$newline$GAIA_MESSAGE_HEREDOC_VIEW$newline" == *"${newline}env$newline"* ]]; then
        echo "not masked: ${row#*|}"
        echo "view: $GAIA_MESSAGE_HEREDOC_VIEW"
        failures=$((failures + 1))
      fi
    elif [ "$GAIA_MESSAGE_HEREDOC_VIEW" != "$text" ]; then
      echo "masked but should be kept: ${row#*|}"
      echo "view: $GAIA_MESSAGE_HEREDOC_VIEW"
      failures=$((failures + 1))
    fi
  done
  [ "$failures" -eq 0 ]
}

@test "a quoted cat heredoc that is the message of git commit or gh pr/issue is masked" {
  check_rows \
    "mask|git commit -m \"\$(cat <<'EOF'\nfix: tidy the output\n\nenv\nEOF\n)\"" \
    "mask|git commit -m \"\$(cat <<\"EOF\"\nenv\nEOF\n)\"" \
    "mask|git commit -m \"\$(cat << 'EOF'\nenv\nEOF\n)\"" \
    "mask|git commit --message \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "mask|git commit --message=\"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "mask|git -C /repo/path commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "mask|git -C \"/repo/a path\" commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "mask|git add a.sh && git commit -m \"\$(cat <<'EOF'\nfix: a -> b; c & d | e\nenv\nEOF\n)\"" \
    "mask|echo 'a\nb' && git commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "mask|git add a.sh\ngit commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "mask|git commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\" && git push" \
    "mask|gh pr create --draft --title t --body \"\$(cat <<'EOF'\nprintenv\nEOF\n)\"" \
    "mask|gh pr edit 12 -b \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "mask|gh issue create -R o/r --title t --body=\"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "mask|gh issue comment 12 --body \"\$(cat <<'EOF'\nenv\nEOF\n)\""
}

# bats test_tags=protected
@test "a body holding a quote, parenthesis, backtick, backslash or \$ is kept" {
  # bash 3.2 scans a substitution's body as shell text: a ) ends it early, and
  # an unpaired quote, backtick, (, $( or trailing backslash changes what that
  # scan pairs. The view refuses each character whole, so every row keeps the
  # body judged.
  check_rows \
    "keep|git commit -m \"\$(cat <<'EOF'\nx ) y\nenv\nEOF\n)\"" \
    "keep|git commit -m \"\$(cat <<'EOF'\nfix (scope)\nenv\nEOF\n)\"" \
    "keep|git commit -m \"\$(cat <<'EOF'\nopen ( only\nenv\nEOF\n)\"" \
    "keep|git commit -m \"\$(cat <<'EOF'\ndon't\nenv\nEOF\n)\"" \
    "keep|git commit -m \"\$(cat <<'EOF'\nsay \"hi\"\nenv\nEOF\n)\"" \
    "keep|git commit -m \"\$(cat <<'EOF'\na \`id\` b\nenv\nEOF\n)\"" \
    "keep|git commit -m \"\$(cat <<'EOF'\ncost \$5\nenv\nEOF\n)\"" \
    "keep|git commit -m \"\$(cat <<'EOF'\ntrail \\\\\nenv\nEOF\n)\""
}

# bats test_tags=protected
@test "an opener, delimiter, closing line or second heredoc outside the shape is kept" {
  check_rows \
    "keep|git commit -m \"\$(cat <<EOF\nenv\nEOF\n)\"" \
    "keep|git commit -m \"\$(cat <<-'EOF'\nenv\nEOF\n)\"" \
    "keep|git commit -m \"\$(cat <<EOFE\nenv\nOF\n)\"" \
    "keep|git commit -m \"\$(cat <<'E)F'\nenv\nE)F\n)\"" \
    "keep|git commit -m \"\$(cat <<'EOF')\"\nenv\nEOF" \
    "keep|git commit -m \"\$(cat <<'EOF' extra\nenv\nEOF\n)\"" \
    "keep|git commit -m \"\$(cat <<'EOF\"\nenv\nEOF\n)\"" \
    "keep|git commit -m \"\$(cat <<'EOF'\nenv\nEOF" \
    "keep|git commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)" \
    "keep|git commit -m \"\$(cat <<'EOF'\nenv\n EOF\n)\"" \
    "keep|git commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\" && cat > f <<'X'\nprintenv\nX"
}

# bats test_tags=protected
@test "a substitution handed to anything but a git commit or gh pr/issue create, edit or comment message flag is kept" {
  check_rows \
    "keep|bash -c \"\$(cat <<'EOF'\nprintenv\nEOF\n)\"" \
    "keep|eval \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "keep|git log --grep \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "keep|git log -m \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "keep|git commit -F \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "keep|git commit -m x \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "keep|gh api -f body=\"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "keep|gh pr merge 12 --body \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "keep|GIT_EDITOR=true git commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "keep|sh -c git commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\""
}

# bats test_tags=protected
@test "a prefix the recognizer cannot read as plain words is kept" {
  check_rows \
    "keep|cd \$HOME && git commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "keep|git commit '--message=\"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "keep|echo 'a\ngit commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "keep|git -C \"\$root\" commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "keep|(git commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\")" \
    "keep|# note\ngit commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "keep|git commit 2>/dev/null -m \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "keep|git \\\\\n  commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\""
}

@test "a text past the character bound is kept" {
  local filler text
  filler=$(printf '%*s' 16400 '' | tr ' ' a)
  text=$(printf "git commit -m \"\$(cat <<'EOF'\n%s\nenv\nEOF\n)\"" "$filler")
  gaia_message_heredoc_view "$text"
  [ "$GAIA_MESSAGE_HEREDOC_VIEW" = "$text" ]
}

@test "a long plain body is masked within a time budget on /bin/bash" {
  # The mask once used a per-character pattern substitution, quadratic on bash
  # 3.2: a 16 KB body took minutes and the hook was cancelled at its deadline.
  local line text view start elapsed
  line=$(printf '%*s' 79 '' | tr ' ' a)
  text="git commit -m \"\$(cat <<'EOF'"$'\n'
  while [ "${#text}" -lt 15000 ]; do text+="$line"$'\n'; done
  text+="EOF"$'\n'")\""
  start=$SECONDS
  view=$(/bin/bash -c '. "$1"; gaia_message_heredoc_view "$2"; printf "%s" "$GAIA_MESSAGE_HEREDOC_VIEW"' _ "$LIBRARY_FILE" "$text")
  elapsed=$(( SECONDS - start ))
  [ "$elapsed" -le 3 ]
  [ "${#view}" -eq "${#text}" ]
  [ "$view" != "$text" ]
}
