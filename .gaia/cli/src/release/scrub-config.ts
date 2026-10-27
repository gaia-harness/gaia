import {load as parseYaml} from 'js-yaml';
import {z} from 'zod';
import {readFileSync} from 'node:fs';

const MarkerStripSchema = z.object({
  end: z.string().min(1),
  paths: z.array(z.string().min(1)).min(1),
  start: z.string().min(1),
  type: z.literal('marker-strip'),
});

const leakCheckBaseShape = {
  description: z.string().optional(),
  id: z.string().min(1),
  'line-allowlist': z.array(z.string()).optional(),
  'path-allowlist': z.array(z.string()).optional(),
  scope: z.array(z.string().min(1)).min(1),
};

// A static check runs a literal regex line-by-line. A derived check builds its
// match set at scan time instead, from `.gaia/release-exclude`, so it cannot
// drift away from the manifest the way a hand-maintained alternation does:
//   - `excluded-slugs`: the release-excluded wiki-slug set (wikilink-to-excluded).
//   - `excluded-workflows`: release-excluded `.github/workflows/*.yml` that never
//     reach an adopter, a directory no path
//     alternation can blanket because some workflows ship and some do not.
//   - `excluded-titles`: the release-excluded wiki page-title set, matched as
//     bare Title-Case prose (the leak the checks above each miss).
//   - `excluded-refs`: excluded paths, slash commands, agent names, and code
//     file names referenced anywhere in the shipped tree (`excluded-refs.ts`).
//
// Every member of the check union parses strictly, so an unknown key is rejected
// rather than silently stripped. This matters most for `title-opt-out` and
// `ref-opt-out`, each valid ONLY on its own variant: a strip-and-pass would drop
// a maintainer's opt-out and ship the very leak it guards against.
const StaticLeakCheckSchema = z.strictObject({
  ...leakCheckBaseShape,
  pattern: z.string().min(1),
});

const OtherDerivedLeakCheckSchema = z.strictObject({
  ...leakCheckBaseShape,
  derive: z.literal(['excluded-slugs', 'excluded-workflows']),
});

const TitleDerivedLeakCheckSchema = z.strictObject({
  ...leakCheckBaseShape,
  derive: z.literal('excluded-titles'),
  // Titles subtracted from the derived set by case-sensitive exact equality.
  // The generics that appear in ordinary prose on nearly every page live here.
  'title-opt-out': z.array(z.string()).optional(),
});

const RefsDerivedLeakCheckSchema = z.strictObject({
  ...leakCheckBaseShape,
  derive: z.literal('excluded-refs'),
  // Tokens subtracted from the derived set by exact equality: paths excluded
  // only to withhold GAIA's own copy, where adopters create their own.
  'ref-opt-out': z.array(z.string()).optional(),
});

// `scope-skip` subtracts paths from every check in the transform, so the one
// class of file no token check can read usefully (a binary, whose bytes decoded
// as UTF-8 are noise a regex can match by accident) is named once rather than
// once per check. It is deliberately NOT a performance lever: scanning the whole
// staged tree, minified CLI bundle and lockfile included, costs ~80ms, and the
// bundle is a shipped file where a leak is as real as anywhere else.
const LeakCheckSchema = z.object({
  checks: z
    .array(
      z.union([
        TitleDerivedLeakCheckSchema,
        RefsDerivedLeakCheckSchema,
        OtherDerivedLeakCheckSchema,
        StaticLeakCheckSchema,
      ])
    )
    .min(1),
  'scope-skip': z.array(z.string().min(1)).optional(),
  type: z.literal('leak-check'),
});

const JsonStripSchema = z.object({
  keys: z.array(z.string().min(1)).min(1),
  paths: z.array(z.string().min(1)).min(1),
  type: z.literal('json-strip'),
});

// Removes a single array element by predicate, the shape `json-strip` cannot
// express (it deletes object keys only). A selector's `path` walks the JSON by
// dot notation; a `[]` suffix on a segment marks an array to iterate, and the
// final `[]` segment names the array elements are removed from. `match` is a
// non-empty key→value map; an element is removed only when every match entry
// equals the element's own value, so a stale selector that matches nothing is a
// silent no-op rather than a corruption of the shipped file.
const JsonStripArrayElementSchema = z.object({
  paths: z.array(z.string().min(1)).min(1),
  selectors: z
    .array(
      z.object({
        match: z
          .record(z.string(), z.string())
          .refine((entries) => Object.keys(entries).length > 0, {
            message: 'match requires at least one key',
          }),
        path: z.string().min(1),
      })
    )
    .min(1),
  type: z.literal('json-strip-array-element'),
});

// Strict like the leak checks: a misspelled key here would otherwise be
// stripped and the transform would run against a default it never had.
const PnpmMemberStripSchema = z.strictObject({
  lockfile: z.string().min(1),
  member: z.string().min(1),
  type: z.literal('pnpm-member-strip'),
  workspace: z.string().min(1),
});

const ConfigSchema = z.object({
  transforms: z
    .array(
      z.union([
        MarkerStripSchema,
        JsonStripSchema,
        JsonStripArrayElementSchema,
        PnpmMemberStripSchema,
        LeakCheckSchema,
      ])
    )
    .min(1),
});

export type DerivedLeakCheck =
  | z.infer<typeof OtherDerivedLeakCheckSchema>
  | z.infer<typeof RefsDerivedLeakCheckSchema>
  | z.infer<typeof TitleDerivedLeakCheckSchema>;

export type JsonStripArrayElementTransform = z.infer<
  typeof JsonStripArrayElementSchema
>;

export type JsonStripTransform = z.infer<typeof JsonStripSchema>;

export type LeakCheckEntry = LeakCheckTransform['checks'][number];

export type LeakCheckTransform = z.infer<typeof LeakCheckSchema>;

export type MarkerStripTransform = z.infer<typeof MarkerStripSchema>;

export type PnpmMemberStripTransform = z.infer<typeof PnpmMemberStripSchema>;

export type RefsDerivedLeakCheck = z.infer<typeof RefsDerivedLeakCheckSchema>;

export type ScrubConfig = z.infer<typeof ConfigSchema>;

export type StaticLeakCheck = z.infer<typeof StaticLeakCheckSchema>;

export type TitleDerivedLeakCheck = z.infer<typeof TitleDerivedLeakCheckSchema>;

export const loadConfig = (configPath: string): ScrubConfig => {
  const raw = readFileSync(configPath, 'utf8');
  const parsed = parseYaml(raw);

  return ConfigSchema.parse(parsed);
};
