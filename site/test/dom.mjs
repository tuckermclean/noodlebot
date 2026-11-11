// Shared helper of the explorer's node:test files (not itself a test): a small HTML/SVG string reader, so the tests
// check the structure of what the views render, not its text layout. No DOM.
//   parse(html) -> root {tag: '#root', attrs: {}, children, text}
//   each element: {tag, attrs (values unescaped: &amp; &lt; &gt; &quot; &#39;), children: [elements], text}
//     text = the text of the element and everything inside it, tags removed, unescaped, spaces collapsed.
//   all(root, pred) -> every element (document order) for which pred(el) is true; one(...) -> the first or undefined
//   by(root, attr, value?) -> every element with the attribute (and that value when given)
const VOID = new Set(['br', 'hr', 'img', 'input', 'meta', 'link', 'rect', 'path', 'line', 'circle', 'polyline', 'use']);
const unesc = (s) => s.replace(/&(amp|lt|gt|quot|#39);/g, (m, c) => ({ amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'" })[c]);

export function parse(html) {
  const root = { tag: '#root', attrs: {}, children: [], text: '', raw: [] };
  const stack = [root];
  const re = /<(\/?)([a-zA-Z][\w:-]*)((?:\s+[\w:.-]+(?:="[^"]*")?)*)\s*(\/?)>|([^<]+)/g;
  let m;
  while ((m = re.exec(html))) {
    const top = stack[stack.length - 1];
    if (m[5] !== undefined) { for (const el of stack) el.raw.push(m[5]); continue; }
    const [, close, tag, attrs, selfClose] = m;
    if (close) {
      for (let i = stack.length - 1; i > 0; i--) if (stack[i].tag === tag) { stack.length = i; break; }
      continue;
    }
    const el = { tag, attrs: {}, children: [], raw: [] };
    for (const a of attrs.matchAll(/([\w:.-]+)(?:="([^"]*)")?/g)) el.attrs[a[1]] = a[2] === undefined ? '' : unesc(a[2]);
    top.children.push(el);
    if (!selfClose && !VOID.has(tag.toLowerCase())) stack.push(el);
  }
  const fin = (el) => { el.text = unesc(el.raw.join(' ')).replace(/\s+/g, ' ').trim(); delete el.raw; el.children.forEach(fin); };
  fin(root);
  return root;
}

export function all(el, pred, out = []) {
  for (const c of el.children) { if (pred(c)) out.push(c); all(c, pred, out); }
  return out;
}
export const one = (el, pred) => all(el, pred)[0];
export const by = (el, attr, value) => all(el, (e) => attr in e.attrs && (value === undefined || e.attrs[attr] === value));
