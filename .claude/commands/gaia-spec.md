---
name: gaia-spec
description: Authors an immutable SPEC artifact through Socratic discovery, then plans it in the same session and stops at the plan's KICKOFF prompt; execution starts in a fresh session. Pass `auto` before the description for a non-interactive mode that answers its own questions. Use when the user asks to write a spec, specify a feature, or pin down requirements before planning.
argument-hint: "[auto] [description]"
---

Run the GAIA **spec** workflow with these arguments: `$ARGUMENTS`

Read `.claude/skills/gaia/references/spec.md` from the project root and follow it exactly. Treat the arguments above as the reference's `$ARGUMENTS`.

`spec.md` routes each run to these sub-references. Read one only when a line in `spec.md`, or in the sub-reference it routes to, says to, and then read what that line names:

- `.claude/skills/gaia/references/spec/auto-mode.md`: the Auto-mode rules, only when the run is in auto mode.
- `.claude/skills/gaia/references/spec/lifecycle.md`: step 2's pre-flight sweep, that section alone.
- `.claude/skills/gaia/references/spec/resume.md`: step 2, only when the allocator reports a draft and the run is interactive.
- `.claude/skills/gaia/references/spec/spec-template.md`: step 3's skeleton and step 7's draft.
- `.claude/skills/gaia/references/spec/clarify-loop.md`, `.claude/skills/gaia/references/spec/clarify-prompts.md` and `.claude/skills/gaia/references/spec/system-prompt.md`: step 5's Socratic loop; `clarify-loop.md` also owns step 6's requirements file.
- `.claude/skills/gaia/references/spec/research.md`: step 5e's research dispatch, only when a question needs research, and its `## The code map` section, which step 8's code map slot sends the reader to.
- `.claude/skills/gaia/references/spec/audit.md` and `.claude/skills/gaia/references/spec/lens-dispatch.md`: step 8's review; `audit.md` routes to `.claude/skills/gaia/references/spec/audit-refuter.md` only when a lens raises a critical finding. The lens agents read `.claude/skills/gaia/references/spec/lenses.md` and the fixer reads `.claude/skills/gaia/references/spec/audit-fixer.md`; the main thread reads neither, except that a lens the main thread runs inline reads its own section of `lenses.md`.
