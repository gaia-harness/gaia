import {z} from 'zod';

// The secret signs every session cookie, so a short one is guessable: 32
// random hex or base64 characters carry at least 128 bits. Production only:
// `pnpm dev` runs as development, so the short value in `.env.example` works
// there, while `pnpm start` runs as production and needs a longer one.
const minimumProductionSessionSecretLength = 32;

const baseSchema = z.object({
  API_URL: z.string(),
  COMMIT_SHA: z
    .string()
    .optional()
    .transform((value) => value?.slice(0, 6)),
  MSW_ENABLED: z.stringbool().optional(),
  NODE_ENV: z.string(),
  npm_package_version: z.string(),
  SESSION_SECRET: z.string(),
  SITE_URL: z.string(),
});

// An allowlist, so a variable added to `schema` stays server-only until it is
// exposed here on purpose: `envClient` is serialized into every page's HTML.
const clientSchema = baseSchema.pick({
  API_URL: true,
  COMMIT_SHA: true,
  MSW_ENABLED: true,
  NODE_ENV: true,
  npm_package_version: true,
});

// Refined after `clientSchema` is picked, because `pick` refuses a refined
// schema. `when` keeps the rule running beside another invalid variable, so one
// parse reports every error; Zod skips a refinement after an earlier issue otherwise.
const schema = baseSchema.refine(
  ({NODE_ENV, SESSION_SECRET}: {NODE_ENV?: string; SESSION_SECRET?: string}) =>
    NODE_ENV !== 'production' ||
    (SESSION_SECRET?.length ?? 0) >= minimumProductionSessionSecretLength,
  {
    error: `SESSION_SECRET must be at least ${minimumProductionSessionSecretLength} characters in production`,
    path: ['SESSION_SECRET'],
    when: () => true,
  }
);

export const env = schema.parse(process.env);

export const envClient = clientSchema.parse(process.env);

type Environment = z.infer<typeof clientSchema>;

// `app/root.tsx` populates `window.process` on every render, so these fields
// are present in the running app. Storybook is deliberately exempt:
// `.storybook/preview-head.html` seeds `window.process = {env: {}}` and the
// preview inlines nothing, so under a story every field reads `undefined`
// despite the type. Give a story the values it needs as args.
declare global {
  // eslint-disable-next-line @typescript-eslint/consistent-type-definitions -- global augmentation of `Window` needs an interface to merge
  interface Window {
    process: {
      env: Environment;
    };
  }
}
