import {describe, expect, test} from 'vitest';
import {parseHtml, serializeForm} from '../.playwright/html';

const parseFirstForm = (markup: string) => {
  const [form] = parseHtml(markup).querySelectorAll('form');

  return form;
};

type FormHtml = ReturnType<typeof parseFirstForm>;

describe('serializeForm serializes the fields a browser would submit', () => {
  test.each(
    [
      {
        expected: [
          {
            color: 'blue',
            intent: 'create',
            note: 'final',
            size: 'small',
            title: 'Hello',
          },
        ],
        markup: `
      <form>
        <input name="title" value="Hello" />
        <input type="hidden" name="intent" value="create" />
        <select name="color">
          <option value="red">Red</option>
          <option value="blue" selected>Blue</option>
        </select>
        <select name="size">
          <option value="small">Small</option>
          <option value="large">Large</option>
        </select>
        <input type="checkbox" name="subscribe" value="yes" />
        <input name="locked" value="nope" disabled />
        <input name="note" value="draft" />
      </form>
    `,
        name: 'serializes the fields a browser would submit and applies an override',
        serialize: (form: FormHtml) => [
          serializeForm(form, {overrides: {note: 'final'}}),
        ],
      },
      {
        expected: [{a: 'yes', b: 'on'}],
        markup: `
      <form>
        <input type="checkbox" name="a" value="yes" checked />
        <input type="checkbox" name="b" checked />
      </form>
    `,
        name: 'submits a checked checkbox value, or on when it has none',
        serialize: (form: FormHtml) => [serializeForm(form)],
      },
      {
        expected: [{bio: 'About me', plan: 'pro'}],
        markup: `
      <form>
        <input type="radio" name="plan" value="free" />
        <input type="radio" name="plan" value="pro" checked />
        <textarea name="bio">About me</textarea>
      </form>
    `,
        name: 'submits only the checked radio and a textarea text',
        serialize: (form: FormHtml) => [serializeForm(form)],
      },
      {
        expected: [{title: 'Hi'}, {intent: 'save', title: 'Hi'}],
        markup: `
      <form>
        <input name="title" value="Hi" />
        <input value="unnamed" />
        <button type="submit" name="intent" value="save">Save</button>
      </form>
    `,
        name: 'omits a submit button and an unnamed input unless the button is the submitter',
        serialize: (form: FormHtml) => {
          const [button] = form.querySelectorAll('button');

          return [
            serializeForm(form),
            serializeForm(form, {submitter: button}),
          ];
        },
      },
      {
        expected: [{open: '1'}],
        markup: `
      <form>
        <input name="open" value="1" />
        <fieldset disabled><input name="shut" value="2" /></fieldset>
      </form>
    `,
        name: 'omits a control inside a disabled fieldset',
        serialize: (form: FormHtml) => [serializeForm(form)],
      },
      {
        expected: [{pick: 'Plain'}],
        markup: `
      <form><select name="pick"><option>  Plain  </option></select></form>
    `,
        name: 'submits an option with no value attribute as its trimmed text',
        serialize: (form: FormHtml) => [serializeForm(form)],
      },
      {
        expected: [{pick: 'a'}],
        markup: `
      <form><select name="pick"><option value="" disabled>Pick</option><option value="a">A</option></select></form>
    `,
        name: 'skips a disabled first option when choosing the default',
        serialize: (form: FormHtml) => [serializeForm(form)],
      },
      {
        expected: [{}],
        markup: `
      <form><select name="pick"><option value="" selected disabled>Pick</option><option value="a">A</option></select></form>
    `,
        name: 'omits a select whose selected option is disabled',
        serialize: (form: FormHtml) => [serializeForm(form)],
      },
      {
        expected: [{pick: 'a'}],
        markup: `
      <form><select name="pick"><optgroup disabled><option value="x">X</option></optgroup><option value="a">A</option></select></form>
    `,
        name: 'skips options inside a disabled optgroup',
        serialize: (form: FormHtml) => [serializeForm(form)],
      },
      {
        expected: [{chosen: 'd'}],
        markup: `
      <form>
        <select name="many" multiple><option value="a">A</option></select>
        <select name="list" size="3"><option value="b">B</option></select>
        <select name="chosen" multiple><option value="c">C</option><option value="d" selected>D</option></select>
      </form>
    `,
        name: 'omits a multiple or listbox select with nothing selected',
        serialize: (form: FormHtml) => [serializeForm(form)],
      },
      {
        expected: [{a: '\nhello'}],
        markup: '<form><textarea name="a">\n\nhello</textarea></form>',
        name: 'drops the single newline a browser strips after the textarea start tag',
        serialize: (form: FormHtml) => [serializeForm(form)],
      },
      {
        expected: [{inLegend: '1'}],
        markup: `
      <form><fieldset disabled>
        <legend><input name="inLegend" value="1" /></legend>
        <legend><input name="inSecond" value="2" /></legend>
        <input name="inBody" value="3" />
      </fieldset></form>
    `,
        name: 'keeps a control in the first legend of a disabled fieldset enabled',
        serialize: (form: FormHtml) => [serializeForm(form)],
      },
      {
        expected: [{pick: 'a b'}],
        markup:
          '<form><select name="pick"><option>  a \n  b  </option></select></form>',
        name: 'collapses internal whitespace in an option text fallback',
        serialize: (form: FormHtml) => [serializeForm(form)],
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {expected, markup, serialize}) => {
    expect(serialize(parseFirstForm(markup))).toEqual(expected);
  });
});
