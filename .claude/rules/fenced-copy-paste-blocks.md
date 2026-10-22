# Fenced Copy-Paste Blocks

Anything the user is meant to copy and paste (a prompt, a handoff, a command, a snippet) goes in exactly one fenced block:

- Three backticks, info string `text` or the code's language. Use four only when the block itself contains a triple-backtick fence.
- Never prose or a blockquote, and never split one paste between a block and prose: nothing the user must paste sits outside the block.
- One block per pasteable item, including copyable lines written into `.md` files (launch commands, `Read <path>` lines, prompts in `STATE.md` or run-folder notes).
- A handoff carries its own context, never a pointer to this session's scrollback.
