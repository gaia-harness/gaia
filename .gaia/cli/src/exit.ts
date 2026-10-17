/**
 * Named exit codes for the gaia CLI. The `/gaia-codify` playbook (`codify.md`) reads these to distinguish
 * payload/config validation failure (PAYLOAD_VALIDATION_FAILED,
 * CONFIG_INVALID) from operational failure (STORAGE_INACCESSIBLE).
 *
 * Codes intentionally leave gaps so that future per-domain ranges
 * (storage: 20–29, config: 30–39) can extend without renumbering.
 *
 * `COULD_NOT_RUN` means a command could not complete, as opposed to finishing
 * with findings. Exit 1 is shared with `UNKNOWN_SUBCOMMAND`, so a consumer of
 * `gaia fitness check` reads exit 1 as "findings exist" only when stdout parses
 * as a check report; exit 1 with any other stdout is a failure to run.
 */
export const EXIT_CODES = {
  CONFIG_INVALID: 30,
  COULD_NOT_RUN: 3,
  INVALID_ARGUMENTS: 2,
  OK: 0,
  PAYLOAD_VALIDATION_FAILED: 11,
  STORAGE_INACCESSIBLE: 20,
  UNKNOWN_SUBCOMMAND: 1,
} as const;

export type ExitCode = (typeof EXIT_CODES)[keyof typeof EXIT_CODES];
