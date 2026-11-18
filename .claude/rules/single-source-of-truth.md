# Single Source of Truth

Every fact has exactly one definition; everything else imports it, derives from it, or points to it. A copy drifts the first time its source changes, and nothing reports the drift.

## Code

A set of values (statuses, roles, locales, route paths, config keys, file globs) or a shared helper has one definition, in any language.

- Before writing a constant list, type, schema, lookup map or helper, search the source and tests for one and reuse it. Search by its values, not its name: a duplicate usually has a different name.
- Derive every other shape from the source, so a new member of the set reaches all of them. In shell, a value or helper two scripts need lives in one sourced library.
- Tests and mocks import the source rather than retyping its values.

## Instruction prose

Each procedure, list, threshold and convention in the Markdown Claude reads (rules, skills, commands, agents, doctrine, wiki pages, `CLAUDE.md` files) lives in one owning file.

- Before writing one, grep for its distinctive literals (command names, paths, flags, numbers), not its title. When an owner exists, point to it.
- Every other file carries only the trigger, when to read it, and the pointer: the owner's path, plus the section heading when it has several. A summary beside the pointer is a second copy; keep only the words the trigger needs.
- A restated copy found stale is deleted and replaced by the pointer, never corrected: a corrected copy starts drifting again.
- Exception: text whose reader cannot open the owner carries its content, such as a handoff or continuation prompt the user pastes into another session.
