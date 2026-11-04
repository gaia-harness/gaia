import {describe, expect, test} from 'vitest';
import {parseHtml, serializeForm} from '../.playwright/html';

const formOf = (markup: string) => {
  const [form] = parseHtml(markup).querySelectorAll('form');

  return form;
};

describe('serializeForm', () => {
  test('serializes the fields a browser would submit and applies an override', () => {
    const form = formOf(`
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
    const form = formOf(`
      <form>
        <input type="checkbox" name="a" value="yes" checked />
        <input type="checkbox" name="b" checked />
      </form>
    `);

    expect(serializeForm(form)).toEqual({a: 'yes', b: 'on'});
  });

  test('submits only the checked radio and a textarea text', () => {
    const form = formOf(`
      <form>
        <input type="radio" name="plan" value="free" />
        <input type="radio" name="plan" value="pro" checked />
        <textarea name="bio">About me</textarea>
      </form>
    `);

    expect(serializeForm(form)).toEqual({bio: 'About me', plan: 'pro'});
  });

  test('omits a submit button and an unnamed input unless the button is the submitter', () => {
    const form = formOf(`
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
    const form = formOf(`
      <form>
        <input name="open" value="1" />
        <fieldset disabled><input name="shut" value="2" /></fieldset>
      </form>
    `);

    expect(serializeForm(form)).toEqual({open: '1'});
  });

  test('replaces a key the form already holds with the override', () => {
    const form = formOf('<form><input name="title" value="form" /></form>');

    expect(serializeForm(form, {overrides: {title: 'override'}})).toEqual({
      title: 'override',
    });
  });

  test('submits an option with no value attribute as its trimmed text', () => {
    const form = formOf(`
      <form><select name="pick"><option>  Plain  </option></select></form>
    `);

    expect(serializeForm(form)).toEqual({pick: 'Plain'});
  });
});
