# Context Discipline

- Keep the main thread lean: it decides, synthesizes, never reads in bulk.
- Fan out read-heavy, low-yield work to sub-agents and keep their returns small.
- Choose each model by task fit, from the table in `wiki/concepts/Workflow Doctrine.md`.
- Research lives under `.notebook/research/<date>-<topic>/`: one small current-state file rewritten in place plus artifacts beside it. Register: `bash .gaia/scripts/notebook/notebook-lib.sh register research <slug> active`; `set-status research <slug> pending` or `closed` (only `closed` is reaped; `wiki/concepts/Notebook.md`).
- Work spanning sessions resumes from one `STATE.md`, rewritten in place, in its run folder (`.gaia/local/runs/`) or research folder; when context runs heavy, the checkpoint says when to save and stop (`wiki/concepts/Workflow Doctrine.md`).
