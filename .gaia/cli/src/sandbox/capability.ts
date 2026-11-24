/**
 * Injectable machine sandbox-capability classifier.
 *
 * Pure: takes a fully-supplied `DetectionInput` and returns a
 * `DetectionResult` with no host I/O. `gaia sandbox detect` (./index.ts)
 * falls back to real host probes (process.platform, `command -v
 * bwrap`/`socat`, WSL detection) for whichever flags are omitted, then
 * calls this function, so the tier, seed and apply tests run deterministically
 * on `ubuntu-latest` CI regardless of the runner's real OS.
 */
export const CAPABILITIES = ['ready', 'needs-deps', 'unsupported'] as const;

export type Capability = (typeof CAPABILITIES)[number];

export type DetectionInput = {
  hasBwrap?: boolean;
  hasSocat?: boolean;
  platform: Platform;
  wsl?: WslKind;
};

export type DetectionResult = {
  capability: Capability;
  installCommand?: string;
  reason: string;
};

export const PLATFORMS = ['darwin', 'linux', 'win32'] as const;

export const WSL_KINDS = ['none', 'wsl1', 'wsl2'] as const;

export type Platform = (typeof PLATFORMS)[number];

export type WslKind = (typeof WSL_KINDS)[number];

const APT_INSTALL_COMMAND = 'sudo apt-get install bubblewrap socat';
const DNF_INSTALL_COMMAND = 'sudo dnf install bubblewrap socat';

export const classifyCapability = (input: DetectionInput): DetectionResult => {
  const {hasBwrap = false, hasSocat = false, platform, wsl = 'none'} = input;

  // Checked first so a nonsensical `wsl` value supplied alongside 'darwin'
  // never overrides the macOS result; `wsl` is only meaningful on linux.
  if (platform === 'darwin') {
    return {
      capability: 'ready',
      reason: 'macOS Seatbelt is built in; nothing to install.',
    };
  }

  if (platform === 'win32' || wsl === 'wsl1') {
    return {
      capability: 'unsupported',
      reason:
        'Native Windows and WSL1 have no bubblewrap/socat sandbox support; use WSL2 instead.',
    };
  }

  if (hasBwrap && hasSocat) {
    return {
      capability: 'ready',
      reason: 'bubblewrap and socat are both installed.',
    };
  }

  return {
    capability: 'needs-deps',
    installCommand: APT_INSTALL_COMMAND,
    reason: `Missing bubblewrap and/or socat. Debian/Ubuntu: ${APT_INSTALL_COMMAND}. Fedora: ${DNF_INSTALL_COMMAND}.`,
  };
};
