/**
 * Credential redaction for everything the fitness namespace prints. Every
 * string in every JSON it emits passes through `redact`, so a finding that
 * quotes a file never leaks a secret that file holds.
 */

/** Known credential shapes. Each pattern is global so `replace` hits every match. */
export const CREDENTIAL_PATTERNS: readonly RegExp[] = [
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)/g,
  /sk-ant-[\w-]{16,}/g,
  /\bsk-[\dA-Za-z]{20,}/g,
  /\bgh[opsur]_[\dA-Za-z]{30,}/g,
  /\bgithub_pat_\w{20,}/g,
  /\bglpat-[\w-]{16,}/g,
  /\b(?:AKIA|ASIA)[\dA-Z]{16}\b/g,
  /\bxox[abeoprs]-[\dA-Za-z-]{10,}/g,
  /\bAIza[\w-]{30,}/g,
  /\bnpm_[\dA-Za-z]{30,}/g,
  /\b[prs]k_(?:live|test)_[\dA-Za-z]{16,}/g,
  /\beyJ[\w-]{10,}\.eyJ[\w-]{10,}\.[\w-]{10,}/g,
];

/** Environment key names that read as secrets (`API_KEY`, `DB_PASSWORD`, ...). */
export const SECRET_KEY_PATTERN =
  /(?:^|_)(?:ACCESS_KEY|API_?KEY|AUTH|CREDENTIALS?|PASSWD|PASSWORD|PRIVATE_KEY|SECRET|TOKEN)(?:_|$)/i;

const REDACTED = '[redacted]';

/** Replaces every credential-pattern match in `text` with `[redacted]`. */
export const redact = (text: string): string =>
  CREDENTIAL_PATTERNS.reduce(
    (current, pattern) => current.replaceAll(pattern, REDACTED),
    text
  );

/** `redact` over every string in a JSON-shaped value; keys are left alone. */
export const redactDeep = <TValue>(value: TValue): TValue => {
  if (typeof value === 'string') return redact(value) as TValue;
  if (Array.isArray(value))
    return value.map((item: unknown) => redactDeep(item)) as TValue;

  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [key, redactDeep(item)])
    ) as TValue;
  }

  return value;
};
