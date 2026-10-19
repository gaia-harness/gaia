# Translation Patterns, Edge Cases

Contents: Core Rule; keyPrefix; Dynamic Translation Keys; Inline Styled Segments (Trans component); String Deduplication; Plurals.

## Core Rule

```tsx
// GOOD
const {t} = useTranslation('pages');
t('onboarding.step1.title'); // 'pages' namespace
t('previous', {ns: 'common'}); // override to 'common'

// BAD
const {t} = useTranslation('pages');
const {t: tc} = useTranslation('common');
```

Choose whichever namespace is used most frequently. If more calls override than use the declared namespace, switch it.

## keyPrefix

`keyPrefix` is useful when many keys share a deep prefix, it keeps `t()` calls short. But it conflicts with `{ns: '...'}` overrides (the prefix is applied before the namespace switch, producing wrong keys). If you need both, drop `keyPrefix` and prefix manually:

```tsx
// GOOD, keyPrefix alone, no namespace overrides needed
const {t} = useTranslation('pages', {keyPrefix: 'onboarding.step1'});
t('title'); // → pages:onboarding.step1.title
t('subtitle'); // → pages:onboarding.step1.subtitle

// BAD, keyPrefix + namespace override: prefix is misapplied
const {t} = useTranslation('pages', {keyPrefix: 'onboarding.step1'});
t('previous', {ns: 'common'}); // ❌ looks up common:onboarding.step1.previous

// GOOD, drop keyPrefix when namespace overrides needed
const {t} = useTranslation('pages');
t('onboarding.step1.title');
t('previous', {ns: 'common'}); // ✓
```

## Dynamic Translation Keys

i18next's typed `t()` only accepts statically-known keys. Template literals with `${string}` fail type-checking.

**Fix:** Ensure the interpolated value has a literal union type, not `string`.

```tsx
// BAD, value is string
const options = values.map((value) => ({
  label: t(`exercises.categoryValues.${value}`), // TS error
  value,
}));

// BAD, casting is a workaround
label: t(`exercises.categoryValues.${value}` as 'exercises.categoryValues.cardio'),

// GOOD, value is ExerciseCategory (literal union), typed at prop/LoaderData level
import type {ExerciseCategory} from '~/services/exercises/types';
// categoryOptions: ExerciseCategory[]  ← typed upstream, no cast needed
const options = categoryOptions.map((value) => ({
  label: t(`exercises.categoryValues.${value}`), // ✓ TypeScript happy
  value,
}));
```

**Where to define the union type:** define it in the module that owns the value set (see the typescript skill's "One Source of Truth" section). Then use it in `LoaderData`, component props, and anywhere else the value flows, the template literal in `t()` will just work.

## Inline Styled Segments (Trans component)

When part of a translated string needs different styling, use `Trans` with XML tags, never split into separate keys:

```ts
// Translation string
previousWorkout: 'Previous <accent>Workout</accent>',
```

```tsx
// Component
import {Trans} from 'react-i18next';

// Pass ns as a separate prop, never embed it in i18nKey.
// i18nKey is namespace-relative: "dashboard.previousWorkout", not "pages:dashboard.previousWorkout"
<Trans
  components={{accent: <span className="text-primary" />}}
  i18nKey="dashboard.previousWorkout"
  ns="pages"
/>;
```

## String Deduplication

Reuse an existing string (check `app/languages/en/common.ts` first) through a namespace override: `t('key', {ns: 'namespace'})`.

### Where shared labels belong

- **Enum display labels** → `common` namespace, snake_case keys matching DB values (enables ``t(`key.${dbValue}`, {ns: 'common'})``)
- **Generic UI actions** (Save, Cancel, Edit, etc.) → already in `common`
- **Page-specific content** → page's namespace

## Plurals

i18next uses `_one`/`_other` key suffixes for pluralization:

```ts
// Translation file (en)
exerciseCount_one: '{{count}} exercise',
exerciseCount_other: '{{count}} exercises',
```

```tsx
// Component, i18next selects the right suffix automatically
t('exerciseCount', {count: n});
```

Always define both `_one` and `_other`. For locales without grammatical plural (e.g. Japanese, Chinese), define only `_other`.
