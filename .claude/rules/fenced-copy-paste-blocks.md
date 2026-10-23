# Fenced Copy-Paste Blocks

- Put each paste for the user, whole, in its own bare three-backtick fence, never prose or a blockquote. Tag only real code; four backticks only around a nested fence.
- Copyable lines in `.md` files each get their own fenced block too.
- A handoff carries its own context, never a pointer to this session's scrollback.
- Why: a tagged or four-backtick fence renders as plain text in Claude Code, losing the copy affordance.
