import type {HTMLElement} from 'node-html-parser';
import {parse} from 'node-html-parser';

/** Parses a server response body so a request-fixture test reads rendered markup with no browser page. */
export const parseHtml = (html: string): HTMLElement => parse(html);
