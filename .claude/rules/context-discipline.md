# Context Discipline

- Keep the main thread lean: it decides, synthesizes, never reads in bulk.
- Fan out read-heavy, low-yield work to sub-agents and keep their returns small.
- Dispatch results follow `.claude/rules/subagent-dispatch.md`.
- Choose each model by task fit, from the table in `wiki/concepts/Workflow Doctrine.md`.
- Research lives under `.notebook/research/<topic>-<date>/`: one small current-state file rewritten in place plus artifacts beside it. Register: `bash .gaia/scripts/notebook/notebook-lib.sh register research <slug> active`; `set-status research <slug> pending` or `closed` (only `closed` is reaped; `wiki/concepts/Notebook.md`).
- Work spanning sessions resumes from one `STATE.md`, rewritten in place, in its run folder (`.gaia/local/runs/`) or research folder; when context runs heavy, the checkpoint says when to save and stop (`wiki/concepts/Workflow Doctrine.md`).
- A prompt or command meant for the user to paste goes in a fenced code block (three backticks, info string `text`), never prose or a blockquote; if it holds a triple-backtick fence, use four. A handoff is such a prompt: it carries its own context, never a pointer to this session's scrollback.
