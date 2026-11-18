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
- Never point at a rule the reader already has loaded. An unscoped rule loads in every session, so nothing points at it. A path-scoped rule loads wherever its `paths:` match, so a file whose own paths fall entirely inside them does not point at it; a partial overlap still needs the pointer. Naming a loaded rule to state an exception to it or a departure from it is not a pointer. Exception: a path-scoped rule loads when a matching file is read, not before the Write that creates one, so a step that creates a file may say to read the rule first.
- A restated copy found stale is deleted and replaced by the pointer, never corrected: a corrected copy starts drifting again.
- Exception: text whose reader cannot open the owner carries its content, such as a handoff or continuation prompt the user pastes into another session.
