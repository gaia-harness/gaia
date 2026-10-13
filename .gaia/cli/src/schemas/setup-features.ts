/**
 * Zod schema for `.gaia/setup-features.json`, the shipped list of setup
 * features a project or machine can decide on.
 *
 * A decision record (one of `SETUP_DECISIONS`) per listed id answers "has this
 * been decided"; `gaia setup drift` compares the list against the records.
 * Unknown extra fields on an entry are stripped on read rather than rejected,
 * so a newer list stays readable by an older CLI, while an unknown `scope` is
 * rejected because a reader cannot know which record file to consult.
 */
import {z} from 'zod';
import {BANNED_DESCRIPTION_CHARACTERS} from './labels.js';

export const SETUP_SCOPES = ['machine', 'project'] as const;

export const SETUP_DECISIONS = [
  'applied',
  'declined',
  'not-applicable',
] as const;

export type SetupDecision = (typeof SETUP_DECISIONS)[number];

export type SetupScope = (typeof SETUP_SCOPES)[number];

export const isSetupDecision = (value: unknown): value is SetupDecision =>
  typeof value === 'string' &&
  (SETUP_DECISIONS as readonly string[]).includes(value);

const KEBAB_CASE_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

const isRepoRelativePath = (value: string): boolean =>
  !value.startsWith('/') && !value.split('/').includes('..');

export const SetupFeatureSchema = z.object({
  admin: z.boolean(),
  id: z.string().regex(KEBAB_CASE_PATTERN),
  reference: z.string().min(1).refine(isRepoRelativePath, {
    message: 'reference must be repo-relative with no ".." segment',
  }),
  required: z.boolean(),
  scope: z.literal(SETUP_SCOPES),
  standalone: z.boolean(),
});

export type SetupFeature = z.infer<typeof SetupFeatureSchema>;

export const SetupFeaturesSchema = z
  .object({
    description: z.string().min(1),
    features: z.array(SetupFeatureSchema),
    version: z.literal(1),
  })
  .superRefine((list, ctx) => {
    const firstIndexById = new Map<string, number>();

    list.features.forEach((feature, index) => {
      const firstIndex = firstIndexById.get(feature.id);

      if (firstIndex === undefined) {
        firstIndexById.set(feature.id, index);

        return;
      }

      ctx.addIssue({
        code: 'custom',
        message: `duplicate setup feature id: ${feature.id} (first at index ${firstIndex})`,
        path: ['features', index, 'id'],
      });
    });

    const bannedCharacter = BANNED_DESCRIPTION_CHARACTERS.find((character) =>
      list.description.includes(character)
    );

    if (bannedCharacter !== undefined) {
      ctx.addIssue({
        code: 'custom',
        message: `description contains a banned character: ${JSON.stringify(bannedCharacter)}`,
        path: ['description'],
      });
    }
  });

export type SetupFeatures = z.infer<typeof SetupFeaturesSchema>;
