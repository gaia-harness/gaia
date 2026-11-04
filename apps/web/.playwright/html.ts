import type {HTMLElement} from 'node-html-parser';
import {parse} from 'node-html-parser';

/** Parses a server response body so a request-fixture test reads rendered markup with no browser page. */
export const parseHtml = (html: string): HTMLElement => parse(html);

export type SerializeFormOptions = {
  overrides?: Record<string, string>;
  submitter?: HTMLElement;
};

const skippedInputTypes = new Set([
  'button',
  'file',
  'image',
  'reset',
  'submit',
]);

const isDisabled = (control: HTMLElement): boolean => {
  if (control.hasAttribute('disabled')) return true;

  for (let node = control.parentNode; node; node = node.parentNode) {
    if (node.tagName === 'FIELDSET' && node.hasAttribute('disabled')) {
      return true;
    }
  }

  return false;
};

const isOptionDisabled = (option: HTMLElement): boolean =>
  option.hasAttribute('disabled') ||
  (option.parentNode?.tagName === 'OPTGROUP' &&
    option.parentNode.hasAttribute('disabled'));

const readSelectedOptionValue = (select: HTMLElement): string | undefined => {
  const options = select.querySelectorAll('option');
  const selected = options.findLast((option) =>
    option.hasAttribute('selected')
  );
  const showsListbox =
    select.hasAttribute('multiple') || Number(select.getAttribute('size')) > 1;
  const chosen =
    selected ??
    (showsListbox ? undefined : (
      options.find((option) => !isOptionDisabled(option))
    ));

  if (!chosen || isOptionDisabled(chosen)) return undefined;

  return chosen.getAttribute('value') ?? chosen.text.trim();
};

const readControlValue = (control: HTMLElement): string | undefined => {
  const tag = control.tagName.toLowerCase();

  if (tag === 'select') return readSelectedOptionValue(control);
  if (tag === 'textarea') return control.text;

  const type = (control.getAttribute('type') ?? 'text').toLowerCase();

  if (skippedInputTypes.has(type)) return undefined;

  if (type === 'checkbox' || type === 'radio') {
    if (!control.hasAttribute('checked')) return undefined;

    return control.getAttribute('value') ?? 'on';
  }

  return control.getAttribute('value') ?? '';
};

/** Serializes the named, enabled controls inside a parsed form element, one value per name with the last winning, so a request-fixture post sends the page's own fields. */
export const serializeForm = (
  form: HTMLElement,
  options: SerializeFormOptions = {}
): Record<string, string> => {
  const {overrides, submitter} = options;
  const fields: Record<string, string> = {};

  // A repeated name keeps its last value; pass the intended one through overrides.
  for (const control of form.querySelectorAll('input, select, textarea')) {
    const name = control.getAttribute('name');
    const value =
      name && !isDisabled(control) ? readControlValue(control) : undefined;

    if (name && value !== undefined) fields[name] = value;
  }

  const submitterName = submitter?.getAttribute('name');

  if (submitter && submitterName) {
    fields[submitterName] = submitter.getAttribute('value') ?? '';
  }

  return {...fields, ...overrides};
};
