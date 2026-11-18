---
spec_id: SPEC-NNN
type: feature
status: in-progress
immutable: true
wiki_promote_default: yes
chain_trigger: gaia-plan
lineage: []
intent: |
  <Plain-language statement of the feature. One paragraph. Captures the
  user-facing change, the user it is for, and the value delivered.
  No implementation detail.>
success_criteria:
  - <Observable outcome that, if true, proves the feature works.>
  - <One bullet per criterion. No internal mechanism, only outcomes
    a human or test can verify from outside the system.>
flows:
  # A flow is a critical user path: breaking it blocks a user's main task or
  # risks data, money or security. No quota and no pinned count. A flow has no
  # branch list and no Given/When/Then. A flow names one critical user path; case tables belong to one parameterized test (.claude/doctrine/testing.md), so list no inputs, branches or outcomes here.
  # A slug may repeat an earlier SPEC's slug on purpose: that flow is covered
  # by extending the existing test file.
  # A page-markup or accessibility structure rule (an element's whole text, a
  # heading level) is never a flow name or a success criterion; the SPEC audit
  # records it as a plan-time directive.
  # Web flow: covers lists folders relative to the frontend package root, and
  # the flow test declares them with @covers.
  - flow_id: FLOW-NNN
    slug: <kebab-case-slug>
    name: <The critical user path, in one line.>
    why: <Why breaking it matters: the main task blocked, or the data, money
      or security at risk.>
    covers: [<folder relative to the frontend package root>, ...]
  # Command flow: test_path is the repo-root-relative test path; covers and
  # @covers apply to web flows only.
  - flow_id: FLOW-NNN
    slug: <kebab-case-slug>
    name: <The critical command path, in one line.>
    why: <Why breaking it matters.>
    test_path: <repo-root-relative test path>
scope_boundaries:
  always:
    - <Behavior that MUST hold for every invocation. Imperative voice.>
  ask_first:
    - <Behavior that requires explicit human confirmation before firing.
      Default direction noted in parentheses if material.>
  never:
    - <Behavior that is forbidden. Imperative voice. No exceptions
      without an explicit reopen ceremony.>
clarifications:
  answered:
    - q: <Question surfaced during the Socratic loop.>
      a: <The settled answer. Captures the decision and the reason
        when the reason is non-obvious.>
  pending: []
research_summary: |
  <Findings from research subagent dispatches during discovery.
  Reference prior art, repo conventions, competitive comparisons.
  Group by dispatch pass when there were multiple. Plain prose.>
created: YYYY-MM-DD
updated: YYYY-MM-DD
---

# <Feature title, short, human-readable, mirrors `intent`>

## One-line summary

<One sentence the human can drop into a PR description without editing.
Names the feature, the surface it lives on, and the user-visible win.>

## Why this exists

<Two or three short paragraphs. The problem the feature solves; the
cost of not building it; the strategic frame that makes this the right
moment to ship it. Plain language, no jargon, no acronyms without
expansion. Treat the reader as an engaged stakeholder, not an implementer.>

## How it behaves (lifecycle / shape)

<Walk the reader through the feature from invocation to outcome.
Diagrams, lifecycle blocks, or numbered phases are welcome. This
section is the cognitive scaffold for the autonomous downstream
pipeline that consumes this SPEC, the clearer this is, the cleaner
the resulting plan and tasks.>

## Behaviors

<Every behavior the feature has, error cases, refusals and security rules
included, one bullet each, with its cases. This SPEC plans no tests: it states
behavior, and the plan decides how each is proven. The bullet below is the
worked example of the shape; replace it with the feature's own.>

- **B1** (access): Only the order's owner can open its receipt page.
  - Case: a signed-in user who owns order 7, opening /orders/7/receipt -> the page shows "Receipt for order 7".
  - Case: a signed-in user who does not own order 7, opening /orders/7/receipt -> 403 and the text "You cannot view this order".

<Rules for this section. Each behavior line is `**B<n>** (<kind>): <sentence>`
as a top-level bullet, with the kind one of `access`, `forgery`, `secret` (the
security kinds), `refusal`, `data-loss` or `other`; `.gaia/scripts/spec/behaviors.mjs`
is the code owner of that list and of the line shapes, and this prose is its one
explanation. Each case line is a two-space-indented bullet `Case: <input> ->
<outcome>` stating the actor, the state, the input and the outcome by value: a
status, a message, a redirect or the literal text shown, never "an error" or
"the usual page". Every behavior has at least one case. Ids and kinds are per
behavior, never per case; ids stay stable across fixes, and a removed id is
never reused. Where the brief already lists values (an action table, labels),
point to it with `REQUIREMENTS.md § <heading>` instead of copying them. Write
no other top-level bullet in this section.>

## Preconditions

<Anything that must be true about the project, environment, or other
specs before this feature can be invoked. List explicitly.>

## Out of scope (for this SPEC)

- <Adjacent capability that belongs in a separate SPEC. Name it; link
  to the SPEC ID once it exists.>
- <Slot reservations: hook signatures or extension points reserved
  here so the contract is stable, but whose logic ships in a later
  SPEC. Mark these clearly.>
- <Adopter-owned end-to-end: behavior only a real backend can show, such
  as data surviving a restart, a database reset, or a production start
  against a real store. Name it here, never as a flow: GAIA's layers run
  against MSW handlers that mirror the API contract, so it belongs to the
  project's own end-to-end suite.>

## Required reading

- <Source document, design lock, or prior SPEC the implementation
  engineer should read before starting.>
- <External reference, upstream tool docs, philosophy doc, video.
  One bullet per source.>

## Cross-references

- <Wikilink or repo-relative path to related decisions, sibling SPECs,
  or downstream targets.>
