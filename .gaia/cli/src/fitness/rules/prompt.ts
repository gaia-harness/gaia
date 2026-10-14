import type {RuleContext} from '../context.js';
import {filesOfKinds} from '../context.js';
import {bodyLines, splitFrontmatter} from '../markdown.js';
import type {
  FileKind,
  ProjectFile,
  PromptModel,
  RawFinding,
  RuleDefinition,
  Severity,
} from '../types.js';

const PROMPT_KINDS: readonly FileKind[] = ['skill', 'command', 'agent'];

/** A line that quotes a phrase to warn against it, so the phrase is not an instruction. */
const NEGATIVE_EXAMPLE = /instead of|avoid|do not write|bad example/i;

const APOSTROPHE = "['’]";

/** The text a line matched, or undefined when it did not match. */
type Matcher = (line: string) => string | undefined;

const phrases = (...alternatives: readonly string[]): Matcher => {
  const expression = new RegExp(
    String.raw`\b(?:${alternatives.join('|')})\b`,
    'i'
  );

  return (line) => expression.exec(line)?.[0];
};

const pattern =
  (expression: RegExp): Matcher =>
  (line) =>
    expression.exec(line)?.[0];

const SENTENCE_BREAK = /(?<=[!.?])\s+/;

/** Matches the first sentence of the line that satisfies every test. */
const sentenceWith =
  (...tests: readonly RegExp[]): Matcher =>
  (line) =>
    line
      .split(SENTENCE_BREAK)
      .find((sentence) => tests.every((test) => test.test(sentence)));

const matchesPhrase = (line: string, matcher: Matcher): boolean => {
  const matched = matcher(line);

  if (matched === undefined) return false;

  // Remove the match first: a rule whose own phrase holds a negative marker
  // ("avoid using tools") must still fire on a line that is otherwise plain.
  return !NEGATIVE_EXAMPLE.test(line.replace(matched, ''));
};

const runsOn = (file: ProjectFile, models: readonly PromptModel[]): boolean =>
  models.includes('any') ||
  (file.model !== 'unresolved' &&
    (models as readonly string[]).includes(file.model));

const promptFiles = (
  context: RuleContext,
  models: readonly PromptModel[]
): readonly ProjectFile[] =>
  filesOfKinds(context, PROMPT_KINDS).filter((file) => runsOn(file, models));

type PhraseRuleOptions = {
  detection: string;
  matcher: Matcher;
  message: string;
  models: readonly PromptModel[];
  remediation: string;
  ruleId: string;
  severity: Severity;
};

const phraseRule = (options: PhraseRuleOptions): RuleDefinition => ({
  appliesTo: PROMPT_KINDS,
  category: 'prompt',
  check: (context) =>
    promptFiles(context, options.models).flatMap((file) =>
      bodyLines(file.text, {inlineCode: true}).flatMap(
        (line, index): readonly RawFinding[] =>
          matchesPhrase(line, options.matcher) ?
            [
              {
                file: file.path,
                line: index + 1,
                message: options.message,
                remediation: options.remediation,
              },
            ]
          : []
      )
    ),
  detection: options.detection,
  models: options.models,
  ruleId: options.ruleId,
  severity: options.severity,
});

const CAPS_EMPHASIS = /\b(?:ALWAYS|CRITICAL|IMPORTANT|MUST|NEVER)\b/;
const EMPHASIS_KEYS: ReadonlySet<string> = new Set([
  'description',
  'when_to_use',
]);
const TOP_LEVEL_KEY = /^([A-Za-z_][\w-]*)\s*:/;

const capsEmphasisFindings = (file: ProjectFile): readonly RawFinding[] => {
  const frontmatter = splitFrontmatter(file.text);

  if (!frontmatter.ok) return [];

  let currentKey = '';

  return frontmatter.raw.split('\n').flatMap((line, index) => {
    const key = TOP_LEVEL_KEY.exec(line)?.[1];

    if (key !== undefined) currentKey = key;

    if (!EMPHASIS_KEYS.has(currentKey)) return [];
    if (NEGATIVE_EXAMPLE.test(line)) return [];

    const emphasis = CAPS_EMPHASIS.exec(line.replace(TOP_LEVEL_KEY, ''))?.[0];

    if (emphasis === undefined) return [];

    return [
      {
        file: file.path,
        // The frontmatter body starts on line 2, after the opening fence.
        line: index + 2,
        message: `The ${currentKey} shouts "${emphasis}" in capitals; current models follow the instruction without emphasis and can overtrigger on it.`,
        remediation:
          'State the same instruction in plain case and say why it matters.',
      },
    ];
  });
};

type TagHit = {line: number};

const TAG = /<(\/?)([A-Za-z][\w-]*)((?:\s[^<>]*?)?)(\/?)>/g;

const tagBalanceFindings = (file: ProjectFile): readonly RawFinding[] => {
  const opens = new Map<string, TagHit[]>();
  const closes = new Map<string, TagHit[]>();

  const plainLines = bodyLines(file.text, {inlineCode: true}).entries();

  for (const [index, line] of plainLines) {
    const tags = NEGATIVE_EXAMPLE.test(line) ? [] : [...line.matchAll(TAG)];

    for (const [, closing, name, , selfClosing] of tags) {
      if (name !== undefined && selfClosing !== '/') {
        const bucket = closing === '/' ? closes : opens;

        bucket.set(name, [...(bucket.get(name) ?? []), {line: index + 1}]);
      }
    }
  }

  return [...closes.keys()].flatMap((name): readonly RawFinding[] => {
    const opening = opens.get(name) ?? [];
    const closing = closes.get(name) ?? [];

    if (opening.length === closing.length) return [];

    const unmatched =
      opening.length > closing.length ?
        opening[closing.length]
      : closing[opening.length];

    return [
      {
        file: file.path,
        line: unmatched?.line ?? 1,
        message: `The tag <${name}> opens ${opening.length} time(s) and closes ${closing.length} time(s).`,
        remediation: `Close every <${name}> with </${name}>, or drop the stray tag.`,
      },
    ];
  });
};

const discouragesTools = phrases(
  'only use tools when',
  'minimi[sz]e tool calls',
  'minimi[sz]e tool use',
  'avoid using tools'
);

const sparingToolSentence = sentenceWith(/\bsparingly\b/i, /\btools?\b/i);

export const PROMPT_RULES: readonly RuleDefinition[] = [
  {
    appliesTo: PROMPT_KINDS,
    category: 'prompt',
    check: (context) =>
      promptFiles(context, ['opus']).flatMap(capsEmphasisFindings),
    detection:
      'A whole-word all-caps CRITICAL, IMPORTANT, MUST, ALWAYS or NEVER in the description or when_to_use frontmatter value.',
    models: ['opus'],
    ruleId: 'prompt.description-caps-emphasis',
    severity: 'info',
  },
  phraseRule({
    detection:
      'An "after" or "every" cadence of N (or a number) tool calls, steps or actions in the same sentence as a summary, status, update or report verb.',
    matcher: sentenceWith(
      /\b(?:after|every)\s+(?:\d+|n)\s+(?:actions|steps|tool calls)\b/i,
      /\b(?:report|status|summar(?:ize|y)|update)/i
    ),
    message:
      'The prompt forces an interim status every few steps, which interrupts long-running work.',
    models: ['opus', 'sonnet'],
    remediation:
      'Ask for a report at the end, or at a real milestone, instead of on a step count.',
    ruleId: 'prompt.no-forced-interim-status',
    severity: 'info',
  }),
  phraseRule({
    detection:
      '"keep" or "make" progress updates or status messages brief, short, minimal or terse.',
    matcher: sentenceWith(
      /\b(?:keep|make)\b/i,
      /\b(?:progress updates?|status messages?)\b/i,
      /\b(?:brief|minimal|short|terse)\b/i
    ),
    message:
      'The prompt asks for terse progress updates, which strips the context a reader needs from them.',
    models: ['fable'],
    remediation:
      'Describe who reads the update and what they need to act on it.',
    ruleId: 'prompt.no-brief-updates',
    severity: 'warning',
  }),
  phraseRule({
    detection:
      '"don\'t", "do not" or "never" followed by "think" or "reason", "without thinking", or "no reasoning".',
    matcher: pattern(
      new RegExp(
        String.raw`\b(?:(?:don${APOSTROPHE}t|do not|never)\s+(?:think|reason)|without thinking|no reasoning)\b`,
        'i'
      )
    ),
    message:
      'The prompt tells the model not to think, which degrades the work on models with native thinking.',
    models: ['opus', 'sonnet'],
    remediation:
      'Remove it; control latency with the effort setting instead of an instruction against thinking.',
    ruleId: 'prompt.no-dont-think',
    severity: 'warning',
  }),
  phraseRule({
    detection:
      '"double-check your answer|work|output", "re-verify before|your", "use a subagent to verify" or "include a final verification step".',
    matcher: pattern(
      /\b(?:double-check your (?:answer|output|work)|re-verify (?:before|your)|use a subagent to verify|include a final verification step)\b/i
    ),
    message:
      'The prompt asks for an extra self-check, which this model performs without being told.',
    models: ['opus'],
    remediation:
      'Delete the instruction; keep a verification step only when it runs a real check such as a test.',
    ruleId: 'prompt.no-explicit-double-check',
    severity: 'info',
  }),
  phraseRule({
    detection:
      '"if in doubt" or "when in doubt" followed by a tool verb, or "default to using".',
    matcher: pattern(
      /\b(?:(?:if|when) in doubt\b[^.\n]*\b(?:call|fetch|grep|invoke|query|read|run|search|use)\b|default to using\b)/i
    ),
    message:
      'The prompt defaults the model to reaching for a tool when unsure, which makes it over-call tools.',
    models: ['opus'],
    remediation:
      'Say when a tool is warranted and let the model decide the rest.',
    ruleId: 'prompt.no-if-in-doubt-tool',
    severity: 'info',
  }),
  phraseRule({
    detection:
      'A <thinking> tag, or "show your reasoning", "write out your reasoning", "explain your reasoning before", "in thinking tags" or "chain of thought".',
    matcher: pattern(
      /<thinking>|\b(?:show your reasoning|write out your reasoning|explain your reasoning before|in thinking tags|chain of thought)\b/i
    ),
    message:
      'The prompt asks the model to extract its reasoning into the reply, which fights native thinking.',
    models: ['opus', 'sonnet', 'fable'],
    remediation:
      'Drop the instruction and let the model think natively; ask for the answer and its justification only when the reader needs it.',
    ruleId: 'prompt.no-reasoning-extraction',
    severity: 'warning',
  }),
  phraseRule({
    detection:
      '"think carefully", "think step by step", "think hard" or "think harder".',
    matcher: phrases(
      'think carefully',
      'think step by step',
      'think hard',
      'think harder'
    ),
    message:
      'The prompt nudges the model to think harder, which this model already does unprompted.',
    models: ['opus'],
    remediation:
      'Delete the nudge; state the task and its constraints instead.',
    ruleId: 'prompt.no-think-carefully',
    severity: 'info',
  }),
  phraseRule({
    detection:
      '"only use tools when", "minimize tool calls", "minimize tool use", "avoid using tools", or "sparingly" in a sentence with "tool".',
    matcher: (line) => discouragesTools(line) ?? sparingToolSentence(line),
    message:
      'The prompt discourages tool use, which makes the model under-use the tools it was given.',
    models: ['sonnet'],
    remediation:
      'Name the situations that call for a tool and leave the rest to the model.',
    ruleId: 'prompt.no-tool-discouragement',
    severity: 'warning',
  }),
  {
    appliesTo: PROMPT_KINDS,
    category: 'prompt',
    check: (context) =>
      promptFiles(context, ['any']).flatMap(tagBalanceFindings),
    detection:
      'For each XML tag name with at least one closing form, the opening and closing counts differ.',
    models: ['any'],
    ruleId: 'prompt.xml-tag-balance',
    severity: 'warning',
  },
];
