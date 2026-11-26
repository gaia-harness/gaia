#!/usr/bin/env bats
#
# Suite for the redaction of a security-class PR review finding. Its detail
# (summary, failure_scenario, file, line) stays in the local record; the PR
# body's `## PR review` section and the session report show only its severity
# and disposition.
#
# Maintainer-only. `.gaia/tests` is release-excluded.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/lib/pr-review-security-redaction.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.claude/hooks/lib/pr-review-verdict.sh"
  HEAD_SHA="1111111111111111111111111111111111111111"
}

# bats test_tags=protected
@test "a security-class finding shows only its severity and disposition in the section and the report, its detail only in the local record" {
  local record
  record=$(jq -n -c --arg head "$HEAD_SHA" '{
    pr: 7, reviewed_head: $head, spec: "present", outcome: "ran",
    findings: [{
      id: "pr-1", file: ".gaia/scripts/a.sh", line: 9, severity: "Major", security: true,
      summary: "the token SECRETSUMMARY is echoed to the log",
      failure_scenario: "SECRETSCENARIO a log reader recovers the token",
      verified: true, disposition: "fix", fix_state: "fixed"
    }]
  }')

  # The detail is present in the local record the renderers read.
  [ "$(jq -r '.findings[0].summary' <<<"$record")" = "the token SECRETSUMMARY is echoed to the log" ] || return 1

  run pr_review_render_report "$record"
  [ "$status" -eq 0 ] || return 1
  case "$output" in *"- Major security finding -> fix"*) ;; *) return 1 ;; esac
  case "$output" in *SECRETSUMMARY*) return 1 ;; esac
  case "$output" in *SECRETSCENARIO*) return 1 ;; esac
  case "$output" in *"a.sh"*) return 1 ;; esac
  case "$output" in *":9"*) return 1 ;; esac

  run pr_review_render_section "$record"
  [ "$status" -eq 0 ] || return 1
  case "$output" in *"- Major security finding -> fixed"*) ;; *) return 1 ;; esac
  case "$output" in *SECRETSUMMARY*) return 1 ;; esac
  case "$output" in *SECRETSCENARIO*) return 1 ;; esac
  case "$output" in *"a.sh"*) return 1 ;; esac
  case "$output" in *":9"*) return 1 ;; esac
}

@test "a security-class finding whose dropped fix was dismissed renders dismissed, never fix, and still hides its reason" {
  local record
  record=$(jq -n -c --arg head "$HEAD_SHA" '{
    pr: 7, reviewed_head: $head, spec: "present", outcome: "ran",
    findings: [{
      id: "pr-1", file: ".gaia/scripts/a.sh", line: 9, severity: "Major", security: true,
      summary: "the token SECRETSUMMARY is echoed to the log",
      failure_scenario: "SECRETSCENARIO a log reader recovers the token",
      verified: true, disposition: "dismiss", reason: "SECRETREASON the line is guarded", fix_state: "dropped"
    }]
  }')

  run pr_review_render_report "$record"
  [ "$status" -eq 0 ] || return 1
  case "$output" in *"- Major security finding -> dismissed"*) ;; *) return 1 ;; esac
  case "$output" in *"-> fix"*) return 1 ;; esac
  case "$output" in *SECRETREASON*) return 1 ;; esac

  run pr_review_render_section "$record"
  [ "$status" -eq 0 ] || return 1
  case "$output" in *"- Major security finding -> dismissed"*) ;; *) return 1 ;; esac
  case "$output" in *SECRETREASON*) return 1 ;; esac
  case "$output" in *SECRETSUMMARY*) return 1 ;; esac
}
