import {describe, expect, test} from 'vitest';
import {parseHtml, serializeForm} from '../.playwright/html';

const parseFirstForm = (markup: string) => {
  const [form] = parseHtml(markup).querySelectorAll('form');

  return form;
};

describe('serializeForm', () => {
  test('serializes the fields a browser would submit and applies an override', () => {
    const form = parseFirstForm(`
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
    `);

    expect(serializeForm(form, {overrides: {note: 'final'}})).toEqual({
      color: 'blue',
      intent: 'create',
      note: 'final',
      size: 'small',
      title: 'Hello',
    });
  });

  test('submits a checked checkbox value, or on when it has none', () => {
    const form = parseFirstForm(`
      <form>
        <input type="checkbox" name="a" value="yes" checked />
        <input type="checkbox" name="b" checked />
      </form>
    `);

    expect(serializeForm(form)).toEqual({a: 'yes', b: 'on'});
  });

  test('submits only the checked radio and a textarea text', () => {
    const form = parseFirstForm(`
      <form>
        <input type="radio" name="plan" value="free" />
        <input type="radio" name="plan" value="pro" checked />
        <textarea name="bio">About me</textarea>
      </form>
    `);

    expect(serializeForm(form)).toEqual({bio: 'About me', plan: 'pro'});
  });

  test('omits a submit button and an unnamed input unless the button is the submitter', () => {
    const form = parseFirstForm(`
      <form>
        <input name="title" value="Hi" />
        <input value="unnamed" />
        <button type="submit" name="intent" value="save">Save</button>
      </form>
    `);
    const [button] = form.querySelectorAll('button');

    expect(serializeForm(form)).toEqual({title: 'Hi'});
    expect(serializeForm(form, {submitter: button})).toEqual({
      intent: 'save',
      title: 'Hi',
    });
  });

  test('omits a control inside a disabled fieldset', () => {
    const form = parseFirstForm(`
      <form>
        <input name="open" value="1" />
        <fieldset disabled><input name="shut" value="2" /></fieldset>
      </form>
    `);

    expect(serializeForm(form)).toEqual({open: '1'});
  });

  test('submits an option with no value attribute as its trimmed text', () => {
    const form = parseFirstForm(`
      <form><select name="pick"><option>  Plain  </option></select></form>
    `);

    expect(serializeForm(form)).toEqual({pick: 'Plain'});
  });

  test('skips a disabled first option when choosing the default', () => {
    const form = parseFirstForm(`
      <form><select name="pick"><option value="" disabled>Pick</option><option value="a">A</option></select></form>
    `);

    expect(serializeForm(form)).toEqual({pick: 'a'});
  });

  test('omits a select whose selected option is disabled', () => {
    const form = parseFirstForm(`
      <form><select name="pick"><option value="" selected disabled>Pick</option><option value="a">A</option></select></form>
    `);

    expect(serializeForm(form)).toEqual({});
  });

  test('skips options inside a disabled optgroup', () => {
    const form = parseFirstForm(`
      <form><select name="pick"><optgroup disabled><option value="x">X</option></optgroup><option value="a">A</option></select></form>
    `);

    expect(serializeForm(form)).toEqual({pick: 'a'});
  });

  test('omits a multiple or listbox select with nothing selected', () => {
    const form = parseFirstForm(`
      <form>
        <select name="many" multiple><option value="a">A</option></select>
        <select name="list" size="3"><option value="b">B</option></select>
        <select name="chosen" multiple><option value="c">C</option><option value="d" selected>D</option></select>
      </form>
    `);

    expect(serializeForm(form)).toEqual({chosen: 'd'});
  });

  test('drops the single newline a browser strips after the textarea start tag', () => {
    const form = parseFirstForm(
      '<form><textarea name="a">\n\nhello</textarea></form>'
    );

    expect(serializeForm(form)).toEqual({a: '\nhello'});
  });

  test('keeps a control in the first legend of a disabled fieldset enabled', () => {
    const form = parseFirstForm(`
      <form><fieldset disabled>
        <legend><input name="inLegend" value="1" /></legend>
        <legend><input name="inSecond" value="2" /></legend>
        <input name="inBody" value="3" />
      </fieldset></form>
    `);

    expect(serializeForm(form)).toEqual({inLegend: '1'});
  });

  test('collapses internal whitespace in an option text fallback', () => {
    const form = parseFirstForm(
      '<form><select name="pick"><option>  a \n  b  </option></select></form>'
    );

    expect(serializeForm(form)).toEqual({pick: 'a b'});
  });
});
