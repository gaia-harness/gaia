---
type: dependency
status: active
package: zod
role: schema-validation
created: 2026-04-20
updated: 2026-11-09
tags: [dependency, validation]
---

# Zod

Schema validation. Used for form validation ([[Conform]]), API response parsing (`parsers.ts`), env var validation (`apps/web/app/env.server.ts`), and TypeScript type inference. See [[API Service Pattern]] and [[Form Components]].

## Zod 4

This project uses Zod 4 in every schema. Most Zod 3 forms still compile; several fail typecheck, among them single-arg `z.record()`, `.args().returns()`, `.deepPartial()`, `z.string().ip()`, and the `required_error` / `invalid_type_error` / `errorMap` params. `.strict()` compiles and lints clean, so reach for `z.strictObject()` deliberately. The deprecated forms `.passthrough()`, `z.string().email()` and the other string formats also compile, but `sonarjs/deprecation` flags them; see [[ESLint Fixes]]. The deprecated `message` param compiles too, and lint reports it only on `.refine()` (`zod/require-error-message`), so write `error` yourself.

Import the Conform integration from `@conform-to/zod/v4`.

## Authoritative source, consult before judging a schema

Training memory is an unreliable guide here: it is easy to "correct" valid v4 code back into deprecated v3 code, or to reject a valid form as invalid. The array union `z.literal(['a', 'b'])` in the migration map below is real Zod 4, not a mistake. So before writing a schema you are unsure of, and especially before flagging or rewriting an existing Zod form as wrong, verify it against the installed Zod's official docs and treat them as authoritative over memory.

The docs are hosted, and the package advertises their URLs through the `package.json` auto-discovery convention. Read the URL from the installed package rather than hardcoding it, with `<member>` the workspace member that depends on Zod, such as `apps/web`:

```bash
node -p "require('./<member>/node_modules/zod/package.json').llmsFull"  # https://zod.dev/llms-full.txt, full concatenated docs
node -p "require('./<member>/node_modules/zod/package.json').llms"      # https://zod.dev/llms.txt, curated index
```

WebFetch that URL with a specific question rather than reading it into context, and ask for a verbatim quote of the signature (e.g. "quote the exact `z.literal` signature for multiple values"); WebFetch the smaller index first when the topic is unclear, and fall back to `https://zod.dev/llms-full.txt` if the fields are absent.

Version caveat: these hosted docs track the latest published Zod, not the installed one, so confirm the installed major matches before trusting them with `node -p "require('./<member>/node_modules/zod/package.json').version"`.

## Migration map

| Zod 3, avoid                             | Zod 4, use                            |
| ---------------------------------------- | ------------------------------------- |
| `z.object({…}).strict()`                 | `z.strictObject({…})`                 |
| `z.object({…}).passthrough()`            | `z.looseObject({…})`                  |
| `z.record(z.string())`                   | `z.record(z.string(), z.string())`    |
| `z.string().email()`                     | `z.email()`                           |
| `z.string().url()`                       | `z.url()`                             |
| `z.string().uuid()`                      | `z.uuid()`                            |
| `z.string().datetime()`                  | `z.iso.datetime()`                    |
| `z.enum(['metric', 'imperial'])`         | `z.literal(['imperial', 'metric'])`, values sorted alphanumerically (`z.enum()` is valid Zod 4, but the project standardizes on the literal-array form) |
| `z.function().args(a).returns(b)`        | `z.function({input: [a], output: b})` |
| `z.string({required_error: 'Required'})` | `z.string({error: 'Required'})`       |
| `{message}`, `invalid_type_error`, `errorMap` | the one `error` key: `.min(5, {error: 'Too short'})` |

## Alternatives mentioned in docs

[Yup](https://github.com/jquense/yup), [Superstruct](https://github.com/ianstormtaylor/superstruct)
