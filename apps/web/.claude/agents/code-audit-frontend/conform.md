---
subagents: [react-patterns, typescript]
library: '@conform-to/zod'
---

# Conform + Zod Audit Rules

- `@conform-to/zod` must **always** be imported from the `/v4` subpath. Flag any import from the bare `@conform-to/zod` package as **Critical**. The default export targets Zod v3 and causes a silent runtime failure that typecheck and build do not catch (lint does, via `no-restricted-imports`).

```tsx
// BAD, runtime failure, no build-time error
import {parseWithZod} from '@conform-to/zod';
import {getZodConstraint} from '@conform-to/zod';

// GOOD
import {parseWithZod} from '@conform-to/zod/v4';
import {getZodConstraint} from '@conform-to/zod/v4';
```

- A `useForm` for a form with a Zod schema must pass `constraint: getZodConstraint(schema)`. Flag one that omits it as **Major**: Conform takes `required` from the constraint, so without it no control is marked required, and nothing fails.
- A composed control rendered from `getFieldList()` must be keyed by `field.key`, on the control or its row. Flag one keyed by neither as **Major**: `getInputProps`, `getSelectProps` and `getTextareaProps` leave the key out, so after a list intent a row keyed by position shows the old value. `ConformField` already sets it.
