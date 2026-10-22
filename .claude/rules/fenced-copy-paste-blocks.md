# Fenced Copy-Paste Blocks

Anything the user is meant to copy and paste from chat (a prompt, a handoff, a command, a snippet) goes in exactly one fenced block:

- A bare three-backtick fence with no info string. A language tag only on real code where highlighting helps (`bash`), never on a prompt or prose. Four backticks only when the block itself contains a triple-backtick fence.
- Never prose or a blockquote, and never split one paste between a block and prose: nothing the user must paste sits outside the block.
- One block per pasteable item. Copyable lines written into `.md` files (launch commands, `Read <path>` lines, prompts in `STATE.md` or run-folder notes) each get their own fenced block too.
- A handoff carries its own context, never a pointer to this session's scrollback.

Why: an info string such as `text`, or a four-backtick fence, stops the block rendering as code in Claude Code, so the user loses the copy affordance.
