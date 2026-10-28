---
type: concept
status: active
created: 2026-10-28
updated: 2026-10-28
tags: [concept, claude, github]
---

# Issue Writing

How Claude writes the body of any GitHub issue it files: tech-debt, enhancement, bug, tracking, or anything else. `.claude/rules/issue-writing.md` points every filing here.

## Who reads an issue

Two readers, in priority order:

1. **An agent with a fresh context** that has to act on the issue from its body alone. It has not seen the session that filed it, the files that were open, or the conversation that led to it.
2. **A human** deciding at a glance what the issue is, whether it matters, and what doing it involves.

A body that serves the first reader usually serves the second, as long as it is shaped for reading. A complete body that reads as one paragraph fails the human, and a tidy body that leaves out the evidence fails the agent.

## Shape

These are principles, not a form. Use the ones the issue needs.

- **Open with what and why**, in a short paragraph: the defect or the proposal, and why it matters. A reader who stops there knows what the issue is.
- **Use headings once there is more than one part.** Name each section for what it holds, in the reader's words. A one-part issue needs none.
- **Keep paragraphs short**, one idea each. If a paragraph is doing two jobs, split it.
- **Use a numbered list for steps** that happen in order, a bulleted list for parallel items, and a **table** for measurements, comparisons or anything with columns. Numbers buried in a sentence are hard to compare.
- **Put paths, commands, labels, identifiers and literal values in code spans**, so they can be copied and searched.
- **Make it self-contained.** Name the files, commands, measurements and run ids the reader needs. Never point at this session, a local scratch file, or something only one machine holds.
- **Include anything the reader needs**, whether or not the lists below ask for it. They are prompts for what is usually missing, not a limit on what belongs.

## What each kind of issue usually needs

Prompts, not required headings. Skip what does not apply. Add what the issue needs that no prompt names.

**Tech-debt.** Where the defect is (`path:line`), what breaks and under what input or state, the evidence (a measurement, a run, the cited code's behavior), the fix as steps when it has more than one, how to verify the fix, and the scope boundary: what the fix must not touch. `.gaia/scripts/file-tech-debt.sh` writes the machine lines and the location, then renders the finding's `failure_mode` under `## Problem` and `suggested_fix` under `## Fix`. Both fields are Markdown, so evidence, verification and scope go inside them as paragraphs, lists, tables or sub-headings. The filing recipe, `.claude/skills/file-tech-debt/SKILL.md`, owns what each part must say.

**Enhancement.** The problem or motivation, the proposal, the evidence that it is worth doing, the open questions a design has to settle, what is out of scope, and prior art or related issues.

**Bug.** Steps to reproduce, expected and actual behavior, the environment and version, and what has already been ruled out.

**Tracking or measurement.** What is being measured and why, how to measure it, the baseline, where results get recorded (a table in the body often works), and what ends the issue.

## What stays fixed

Some lines in a body are data, not prose. Other scripts parse them, so they never move or change shape: the tech-debt dedup key comment and the investigate block. [[Audit Disposition and Debt Fix]] owns them. Everything else in the body is Claude's to shape.

<!-- gaia:maintainer-only:start -->
In the maintainer repository, the debt source record on line 2 is fixed too: [[Maintainer-only Debt Source Record]].
<!-- gaia:maintainer-only:end -->

When a skill or script defines a body's format (a report with fixed sections, a scaffold the filing script writes), that format governs, and this page shapes the prose inside it.

No check enforces body shape. A required heading or a length limit would block content the reader needs as often as it caught a bad body.
