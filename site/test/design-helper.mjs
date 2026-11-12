// Shared helpers of the W06 (site-design) node:test files (not itself a test: only *.test.mjs files are run).
//   readSite(name)      the text of a file of site/ (style.css, index.html, ...)
//   cssRules(css)       style.css as a flat list [{media: [prelude, ...], selectors: [..], decls: {prop: value}}]
//                       (comments removed; the rules inside @media / @supports carry that at-rule's prelude)
//   cssImports(css)     the targets of every @import
//   selfAndDesc(el)     the element and everything inside it
//   withAncestors(root, pred)  [{el, parents: [...]}] for each element for which pred is true (document order)
//   hasAncestor(entry, pred)
//   colourLiterals(html) every colour literal (hex, rgb()/hsl()/..., a named colour) in the attributes and <style>
//                       of an HTML/SVG string, as ['<attr>=<value>', ...]; var(--x), none, transparent and
//                       currentColor are not literals
//   makeApp(opts)       createApp over a fake fetch and clock (as app.test.mjs) -> {a, f, clk, fx, location}
import { readFileSync } from 'node:fs';
import { parse, all } from './dom.mjs';
import { loadFixture, clock, fakeFetch } from './helper.mjs';

export const MIN = 60000;
const SITE = new URL('../', import.meta.url);
export const readSite = (name) => readFileSync(new URL(name, SITE), 'utf8');

// ---- CSS
function blocks(src) {
  const out = [];
  let i = 0, depth = 0, start = 0, prelude = '', bodyAt = 0;
  for (; i < src.length; i++) {
    const c = src[i];
    if (c === '{') {
      if (depth === 0) { prelude = src.slice(start, i).trim(); bodyAt = i + 1; }
      depth++;
    } else if (c === '}') {
      depth--;
      if (depth === 0) { out.push({ prelude, body: src.slice(bodyAt, i) }); start = i + 1; }
      if (depth < 0) depth = 0;
    } else if (c === ';' && depth === 0) start = i + 1;
  }
  return out;
}
const decls = (body) => {
  const d = {};
  for (const part of body.split(';')) {
    const j = part.indexOf(':');
    if (j < 0) continue;
    d[part.slice(0, j).trim().toLowerCase()] = part.slice(j + 1).trim();
  }
  return d;
};
export function cssRules(css) {
  const src = css.replace(/\/\*[\s\S]*?\*\//g, '');
  const walk = (text, media) => blocks(text).flatMap(({ prelude, body }) => {
    if (prelude.startsWith('@')) {
      return /^@(media|supports|layer)\b/i.test(prelude) ? walk(body, [...media, prelude.replace(/\s+/g, ' ')]) : [];
    }
    return [{ media, selectors: prelude.split(',').map((s) => s.trim()).filter(Boolean), decls: decls(body) }];
  });
  return walk(src, []);
}
export function cssImports(css) {
  return [...css.replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/@import\s+([^;]+);/gi)].map((m) => m[1].trim());
}

// ---- DOM
export const selfAndDesc = (el) => [el, ...all(el, () => true)];
export function withAncestors(root, pred) {
  const out = [];
  const walk = (el, parents) => {
    for (const c of el.children) {
      if (pred(c)) out.push({ el: c, parents });
      walk(c, [...parents, c]);
    }
  };
  walk(root, [root]);
  return out;
}
export const hasAncestor = (entry, pred) => entry.parents.some(pred);
export const classes = (el) => String(el.attrs.class || '').split(/\s+/).filter(Boolean);

// ---- colour literals
const NAMED = new Set(('aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue blueviolet brown ' +
  'burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue darkcyan darkgoldenrod darkgray ' +
  'darkgreen darkgrey darkkhaki darkmagenta darkolivegreen darkorange darkorchid darkred darksalmon darkseagreen darkslateblue ' +
  'darkslategray darkslategrey darkturquoise darkviolet deeppink deepskyblue dimgray dimgrey dodgerblue firebrick floralwhite ' +
  'forestgreen fuchsia gainsboro ghostwhite gold goldenrod gray green greenyellow grey honeydew hotpink indianred indigo ivory ' +
  'khaki lavender lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan lightgoldenrodyellow lightgray lightgreen ' +
  'lightgrey lightpink lightsalmon lightseagreen lightskyblue lightslategray lightslategrey lightsteelblue lightyellow lime ' +
  'limegreen linen magenta maroon mediumaquamarine mediumblue mediumorchid mediumpurple mediumseagreen mediumslateblue ' +
  'mediumspringgreen mediumturquoise mediumvioletred midnightblue mintcream mistyrose moccasin navajowhite navy oldlace olive ' +
  'olivedrab orange orangered orchid palegoldenrod palegreen paleturquoise palevioletred papayawhip peachpuff peru pink plum ' +
  'powderblue purple rebeccapurple red rosybrown royalblue saddlebrown salmon sandybrown seagreen seashell sienna silver skyblue ' +
  'slateblue slategray slategrey snow springgreen steelblue tan teal thistle tomato turquoise violet wheat white whitesmoke ' +
  'yellow yellowgreen').split(' '));
const COLOUR_ATTRS = new Set(['fill', 'stroke', 'stop-color', 'flood-color', 'lighting-color', 'color', 'bgcolor', 'data-color']);
const SKIP_ATTRS = new Set(['href', 'src', 'd', 'points', 'transform', 'viewbox']);

export function literalsIn(value, named) {
  const v = value.replace(/url\([^)]*\)/gi, ' ').replace(/var\([^)]*\)/gi, ' ');
  const out = [];
  for (const m of v.matchAll(/#[0-9a-fA-F]{3,8}(?![0-9A-Za-z_-])/g)) out.push(m[0]);
  for (const m of v.matchAll(/\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color|color-mix)\s*\(/gi)) out.push(m[0]);
  if (named) {
    for (const t of v.split(/[\s,;:()/]+/)) if (NAMED.has(t.toLowerCase())) out.push(t);
  }
  return out;
}

export function colourLiterals(html) {
  const found = [];
  const root = parse(html);
  for (const el of [...all(root, () => true)]) {
    for (const [k, v] of Object.entries(el.attrs)) {
      if (SKIP_ATTRS.has(k.toLowerCase())) continue;
      const named = COLOUR_ATTRS.has(k.toLowerCase()) || k.toLowerCase() === 'style';
      for (const lit of literalsIn(v, named)) found.push(`${el.tag}[${k}]=${lit}`);
    }
  }
  for (const m of html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/gi)) {
    for (const lit of literalsIn(m[1], true)) found.push(`<style>=${lit}`);
  }
  return found;
}

// ---- the app
export async function makeApp({ search = '?gist=g1', hash = '', start, notFoundConfig = true } = {}) {
  const app = await import('../app.js');
  const fx = loadFixture();
  const clk = clock(start ?? fx.manifest.seen * 1000 + MIN);
  const f = fakeFetch((c) => {
    if (c.url.startsWith('https://api.github.com/gists/')) return { status: 200, headers: { ETag: '"e1"' }, body: fx.gist };
    return notFoundConfig ? { status: 404, body: '' } : { status: 200, body: {} };
  }, clk);
  const location = { search, hash };
  const a = app.createApp({ location, fetch: f, now: clk.now, hidden: clk.hidden });
  return { app, a, f, clk, fx, location };
}
