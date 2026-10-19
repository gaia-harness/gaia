# Zod 4, Zod 3 → Zod 4 Migration Map

## Authoritative source, consult before judging a schema

Zod 4 reworked the API heavily from v3, and most v3 forms still type-check, so training memory is an unreliable guide here: it is easy to "correct" valid v4 code back into deprecated v3 code, or to reject a valid form as invalid. The array union `z.literal(['a', 'b'])` in the migration map below is real Zod 4, not a mistake. So before writing a schema you are unsure of, and especially before flagging or rewriting an existing Zod form as wrong, verify it against the installed Zod's official docs and treat them as authoritative over memory.

The docs are hosted, and the package advertises their URLs through the `package.json` auto-discovery convention. Read the URL from the installed package rather than hardcoding it:

```bash
node -p "require('./frontend/node_modules/zod/package.json').llmsFull"  # https://zod.dev/llms-full.txt, full concatenated docs
node -p "require('./frontend/node_modules/zod/package.json').llms"      # https://zod.dev/llms.txt, curated index
```

WebFetch that URL with a specific question rather than reading it into context, and ask for a verbatim quote of the signature (e.g. "quote the exact `z.literal` signature for multiple values"); WebFetch the smaller index first when the topic is unclear, and fall back to `https://zod.dev/llms-full.txt` if the fields are absent.

Version caveat: these hosted docs track the latest published Zod, not the installed one, so confirm the installed major matches before trusting them with `node -p "require('./frontend/node_modules/zod/package.json').version"`. If the project is ever pinned behind what zod.dev serves, the docs run ahead of the installed API and the memory-versus-reality problem returns.

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

## Strict objects

Use the top-level factories. Of the chained methods only `.passthrough()` is deprecated (use `z.looseObject()`); `.strict()` still works but has the `z.strictObject()` factory, and `.strip()` is the default behavior, so calling it is redundant.

```ts
// BAD, Zod 3 chained method
const Payload = z.object({id: z.string(), tags: z.array(z.string())}).strict();

// GOOD, Zod 4 factory
const Payload = z.strictObject({id: z.string(), tags: z.array(z.string())});
```
