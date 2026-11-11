---
paths:
  - '.claude/skills/**'
  - '.claude/commands/**'
  - '.claude/agents/**'
  - 'apps/web/.claude/skills/**'
  - 'apps/web/.claude/agents/**'
  - 'wiki/concepts/PR Merge Workflow.md'
  - 'wiki/concepts/Audit Round Procedure.md'
  - 'wiki/concepts/Audit Gate Reference.md'
  - 'wiki/concepts/Audit Disposition and Debt Fix.md'
  - 'wiki/concepts/Code Review Audit Agent.md'
  - 'wiki/concepts/Workflow Doctrine.md'
  - 'wiki/decisions/Quality Gate.md'
---

# User Questions

A question whose answer is a choice is an `AskUserQuestion`:

- **Recommended option first**, its label ending ` (Recommended)`. A gate whose contract deliberately recommends nothing (a neutral classification) says so in the question and keeps a fixed option order.
- **Never recommend widening your own authority.** These options are never `(Recommended)`: a standing grant to act past a gate, clearing or waiving a failed gate, merging a plan build's pull request or merging over audit residuals, and a statement that the human did something the next step does not verify. A statement the next step does verify may lead: the human takes a step only they can take (a line in a file the agent may not edit), then what failed reruns and the work continues only on a pass. A failed rerun ends the run and offers no new continuing option, so a picker that takes the recommendation without acting stops one rerun later. Otherwise recommend the conservative option (stay halted, stop for manual handling, hold the merge), or recommend nothing as a neutral classification does, with the conservative option first. A picker that takes the recommendation, such as an unattended driver, would otherwise pass the very halt that asked it. The exception is the audit branch checkpoint, whose `Continue audit in this session`, `Continue audit in a new session` or `Accept the remainder` may lead: its hooks record a grant or an accept only from an interactive CLI session.
- **At most 4 options.** A `Discuss this` escape, where the skill offers one, counts toward the 4. Never list `Other`: the tool adds it, and it keeps a free-form answer available.
- **One question per decision.** Batch independent decisions, up to 4 questions per call, with successive calls when there are more. A decision waits for an earlier answer only when it depends on it; a Socratic or clarify loop, where each answer shapes the next question, stays one question per turn.
- **A review list is one decision.** A set of recommendations the user reviews together (review or audit findings, each with its own recommended action) is not one decision per item: print every item with its recommendation as text, then ask one question, `Accept all as recommended (Recommended)` or `Revise`. `Revise` asks which items to change and what to change, then follows up only on those; every other item keeps its recommendation. The lint-fix and consolidate stages of `/gaia-wiki` stay one question per finding, each for its own reason: a lint-fix finding carries its own option set, with a recommendation that depends on what the cited sentence says; a consolidate `Apply` is an editorial merge, rename or retire whose kind can open a follow-up question (the canonical slug of a near-collision, retire or confirm for a subject-orphan), so each is its own decision.

**How a review list prints.** Plain Markdown, never a blockquote or a code fence, which render with a bar or a box around the text:

- A bold header, `**<review name>: <N> findings need your decision**`, followed by what was already applied, if anything.
- Each finding: a bold line `**<n>. <short plain title>** · <severity>`, a blank line, then three bullets: `**Where:**`, `**Problem:**`, and the quote, either `**The draft says:**` with the text quoted once or `**Evidence:**` with a `file:line`.
- A blank line, then `**Recommendation:**` as its own paragraph, saying what happens and why. It sits outside the bullets because a blank line between bullets makes some renderers space every bullet.
- Findings are numbered 1 to N, and that number is what the user names in `Revise`. Internal finding ids stay in the decision list and are never printed. Every line uses plain language: no ids or phrases coined in the documents the user has not read.

This covers every confirmation and approval ("Does this match?", "Proceed?", "Commit this?", "Accept all or revise?"), every pick-one, and every "choose these or discuss it". Auto-mode, CI and other unattended arms never prompt, so they are out of scope.

**The one exception:** a plain prompt only when the expected answer is genuinely free text (a feature description, a name, a reason). A skill that keeps one plain says why it is open-ended beside it.

Why: a free-text confirmation makes the user type "yes" to an A-or-B question, mixed styles break the flow, and a menu is easier to answer on mobile.
