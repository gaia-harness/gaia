// Deterministic PRNG and shuffle for corpus selection. mulberry32 (Tommy
// Ettinger's 32-bit generator): every step is 32-bit integer arithmetic through
// Math.imul and unsigned shifts, so the same seed gives the same sequence on any
// machine and any Node version. Math.random is never used: it is unseeded and
// engine-specific.

/** A function returning the next float in [0, 1) for the given 32-bit seed. */
export const mulberry32 = (seed) => {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let mixed = state;
    mixed = Math.imul(mixed ^ (mixed >>> 15), mixed | 1);
    mixed ^= mixed + Math.imul(mixed ^ (mixed >>> 7), mixed | 61);
    return ((mixed ^ (mixed >>> 14)) >>> 0) / 4294967296;
  };
};

/** A Fisher-Yates shuffled copy of `items`, driven by mulberry32(seed). */
export const seededShuffle = (items, seed) => {
  const shuffled = [...items];
  const next = mulberry32(seed);
  for (let index = shuffled.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(next() * (index + 1));
    [shuffled[index], shuffled[swapIndex]] = [shuffled[swapIndex], shuffled[index]];
  }
  return shuffled;
};
