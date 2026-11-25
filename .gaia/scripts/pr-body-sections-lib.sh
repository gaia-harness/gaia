# shellcheck shell=bash
#
# The PR-body headings the audit writes its conclusions under, one variable per
# heading, and gaia_pr_body_audit_headings, the set as a list. The writers take
# their heading from here, and the PR review's input bundle strips this set
# from the body so the reviewer never reads what the audit concluded: a heading
# a writer adds here reaches the strip with no edit to the bundle builder.
# Sourced; defines variables and one function, runs nothing else at source
# time. Never `cd`s.

# shellcheck disable=SC2034 # each variable is read by the writer that owns it
PR_BODY_HEADING_AUDIT_ROUNDS='## Audit rounds'
PR_BODY_HEADING_ACCEPTED_RESIDUALS='## Accepted residuals (recorded, not fixed)'
PR_BODY_HEADING_DECIDED_UNATTENDED='## Decided unattended'
PR_BODY_HEADING_OUT_OF_SCOPE='## Out-of-scope machinery findings (recorded, not filed)'
PR_BODY_HEADING_WAIVED='## Waived below triage threshold (not filed)'
PR_BODY_HEADING_CROSS_REMIT_FIXED='## Cross-remit findings fixed after their round'
PR_BODY_HEADING_NOT_FILED='## Not filed (no issue backend)'
PR_BODY_HEADING_CARRY_FORWARD='## Re-run carry-forward ledger'
PR_BODY_HEADING_RED_ADVISORY='## Red advisory checks at merge'
PR_BODY_HEADING_PR_REVIEW='## PR review'

# gaia_pr_body_audit_headings: every audit-written heading, one per line.
gaia_pr_body_audit_headings() {
  printf '%s\n' \
    "$PR_BODY_HEADING_AUDIT_ROUNDS" \
    "$PR_BODY_HEADING_ACCEPTED_RESIDUALS" \
    "$PR_BODY_HEADING_DECIDED_UNATTENDED" \
    "$PR_BODY_HEADING_OUT_OF_SCOPE" \
    "$PR_BODY_HEADING_WAIVED" \
    "$PR_BODY_HEADING_CROSS_REMIT_FIXED" \
    "$PR_BODY_HEADING_NOT_FILED" \
    "$PR_BODY_HEADING_CARRY_FORWARD" \
    "$PR_BODY_HEADING_RED_ADVISORY" \
    "$PR_BODY_HEADING_PR_REVIEW"
}
