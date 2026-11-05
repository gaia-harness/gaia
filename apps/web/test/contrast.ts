// The type and the contrast-ratio math are shared by the Playwright specs
// (Node) and story tests (the browser), so this file imports nothing from
// either side. The canvas color resolution is not shared: `resolveColors` in
// `.playwright/theme.ts` duplicates `resolveColor` below, so keep the two in
// step.

export type Rgba = {a: number; b: number; g: number; r: number};

/** WCAG 1.4.11 minimum contrast for focus indicators and meaningful icons. */
export const MINIMUM_NON_TEXT_CONTRAST = 3;

/**
 * Resolves a CSS color to sRGB bytes in the browser by painting it onto a 1x1
 * canvas, since Chromium reports oklch and color-mix values unconverted. A
 * translucent color is painted over `backdrop` (opaque white by default) so
 * the result is what the user sees.
 */
export const resolveColor = (css: string, backdrop = '#ffffff'): Rgba => {
  const canvas = document.createElement('canvas');
  canvas.width = 1;
  canvas.height = 1;
  const context = canvas.getContext('2d', {willReadFrequently: true});
  if (!context) throw new Error('no 2d canvas context');
  const probe = new Option().style;
  probe.color = css;
  if (probe.color === '') throw new Error(`unparseable color: ${css}`);
  context.fillStyle = backdrop;
  context.fillRect(0, 0, 1, 1);
  context.fillStyle = css;
  context.fillRect(0, 0, 1, 1);
  const [red, green, blue, alpha] = context.getImageData(0, 0, 1, 1).data;

  return {a: alpha / 255, b: blue, g: green, r: red};
};

const linearizeChannel = (channelByte: number): number => {
  const scaled = channelByte / 255;

  return scaled <= 0.03928 ? scaled / 12.92 : ((scaled + 0.055) / 1.055) ** 2.4;
};

const computeLuminance = ({b, g, r}: Rgba): number =>
  0.2126 * linearizeChannel(r) +
  0.7152 * linearizeChannel(g) +
  0.0722 * linearizeChannel(b);

/** WCAG 2.x contrast ratio between two opaque colors. */
export const computeContrastRatio = (first: Rgba, second: Rgba): number => {
  const lighter = Math.max(computeLuminance(first), computeLuminance(second));
  const darker = Math.min(computeLuminance(first), computeLuminance(second));

  return (lighter + 0.05) / (darker + 0.05);
};
