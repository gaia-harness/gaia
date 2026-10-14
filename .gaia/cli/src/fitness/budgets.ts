/**
 * The always-loaded context budgets. This is the single tracked source of the
 * numbers: the claudemd rules read them from here, and the statusline check
 * reads the same constants through the CLI rather than carrying its own copy.
 */

/**
 * Words allowed in the root CLAUDE.md. It loads on every turn of every
 * session, so each word is paid for on every request; 500 words is roughly one
 * screen of rules and keeps the always-on prefix cheap.
 */
export const ROOT_CLAUDE_MD_WORD_BUDGET = 500;

/**
 * Words allowed in a nested CLAUDE.md. It loads whenever Claude works under
 * its folder, on top of the root file, so it gets a tighter allowance than the
 * root.
 */
export const NESTED_CLAUDE_MD_WORD_BUDGET = 400;

/**
 * Lines allowed in one rule file. A rule is meant to be a short, single-topic
 * instruction; past 200 lines it is a manual that belongs in a skill or a wiki
 * page loaded on demand.
 */
export const RULE_LINE_BUDGET = 200;
