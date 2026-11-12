// W06 (site-design), the second slice, colour: W06-AC-1 (the tokens, the themes, one colour per state, no colour
// literal) and W06-AC-2 (WCAG 2 contrast of the pairs of change 2, per theme).
//
// Names the implementation must keep (everything else about the look is free):
//   - colour custom properties on :root of style.css, and the same set again on :root inside
//     @media (prefers-color-scheme: dark): --bg (page background), --surface and --surface-2 (cards, panels, table
//     headers: every --surface and --surface-<x> token is a "surface"), --border, --text, --muted, --link,
//     --accent, --warn (stale/warning text), --held (held warning text), --state-<state> for merged running failed
//     question answered waiting-pr pr-open ready held waiting, and --state-other. A colour property is a custom
//     property whose value (var() chains followed) is a hex, rgb()/rgba() or hsl()/hsla() colour.
//   - the explorer's node label colour is the `fill` of the style.css rule whose selector names `[data-node] text`
//     (not the ghost one); it is tested on every --state-* colour.
//   - a badge is a rule whose selector names `.badge` or `[data-badge`: its `color` is tested on its own
//     `background` (a single var(--token)); a badge rule with `[style]` and no background (the state badge, whose
//     background is an inline var(--state-<state>)) is tested on every --state-* colour.
//   - any other rule of style.css that sets both `color: var(--a)` and `background[-color]: var(--b)` is tested as a
//     pair too (the nav pill, the stale pill, the notice, ...), so is the text on --selected.
// Colours with an alpha are composited over --bg before the ratio is taken; a token that does not resolve to a colour
// where a pair needs it fails the test.
import test from 'node:test';
import assert from 'node:assert/strict';
import { parse, all, one, by } from './dom.mjs';
import { loadFixture } from './helper.mjs';
import { readSite, cssRules, selfAndDesc, literalsIn, colourLiterals, makeApp } from './design-helper.mjs';

const STATES = ['merged', 'running', 'failed', 'question', 'answered', 'waiting-pr', 'pr-open', 'ready', 'held', 'waiting'];
const CSS = readSite('style.css');
const RULES = cssRules(CSS);
const clone = (x) => JSON.parse(JSON.stringify(x));

// ---- tokens
const isRoot = (r) => r.selectors.length > 0 && r.selectors.every((s) => s === ':root');
const isDark = (r) => r.media.length === 1 && /^@media\s*\(\s*prefers-color-scheme\s*:\s*dark\s*\)$/i.test(r.media[0]);
const customProps = (rules) => Object.assign({}, ...rules.map((r) => Object.fromEntries(Object.entries(r.decls).filter(([k]) => k.startsWith('--')))));
const LIGHT = customProps(RULES.filter((r) => isRoot(r) && r.media.length === 0));
const DARK_ONLY = customProps(RULES.filter((r) => isRoot(r) && isDark(r)));
const DARK = { ...LIGHT, ...DARK_ONLY };

function resolve(tokens, value, depth = 0) {
  if (depth > 10) return null;
  let bad = false;
  const out = value.replace(/var\(\s*(--[\w-]+)\s*(?:,\s*([^)]*))?\)/g, (m, name, fb) => {
    const v = tokens[name] !== undefined ? tokens[name] : fb;
    if (v === undefined) { bad = true; return ''; }
    const r = resolve(tokens, v.trim(), depth + 1);
    if (r === null) { bad = true; return ''; }
    return r;
  });
  return bad ? null : out.trim();
}

const BASIC = { white: [255, 255, 255, 1], black: [0, 0, 0, 1] };
function parseColour(v) {
  v = String(v).trim().toLowerCase();
  if (BASIC[v]) return [...BASIC[v]];
  let m = /^#([0-9a-f]{3,8})$/.exec(v);
  if (m) {
    let h = m[1];
    if (h.length === 3 || h.length === 4) h = [...h].map((c) => c + c).join('');
    if (h.length !== 6 && h.length !== 8) return null;
    const n = (i) => parseInt(h.slice(i, i + 2), 16);
    return [n(0), n(2), n(4), h.length === 8 ? n(6) / 255 : 1];
  }
  m = /^rgba?\(\s*([^)]*)\)$/.exec(v);
  if (m) {
    const p = m[1].split(/[\s,/]+/).filter(Boolean);
    if (p.length < 3) return null;
    const ch = (s) => (s.endsWith('%') ? (parseFloat(s) * 255) / 100 : parseFloat(s));
    const a = p[3] === undefined ? 1 : p[3].endsWith('%') ? parseFloat(p[3]) / 100 : parseFloat(p[3]);
    const c = [ch(p[0]), ch(p[1]), ch(p[2]), a];
    return c.some(Number.isNaN) ? null : c;
  }
  m = /^hsla?\(\s*([^)]*)\)$/.exec(v);
  if (m) {
    const p = m[1].split(/[\s,/]+/).filter(Boolean);
    if (p.length < 3) return null;
    const h = (((parseFloat(p[0]) % 360) + 360) % 360) / 360, s = parseFloat(p[1]) / 100, l = parseFloat(p[2]) / 100;
    const a = p[3] === undefined ? 1 : p[3].endsWith('%') ? parseFloat(p[3]) / 100 : parseFloat(p[3]);
    const q = l < 0.5 ? l * (1 + s) : l + s - l * s, pp = 2 * l - q;
    const f = (t) => { t = (t + 1) % 1; return 255 * (t < 1 / 6 ? pp + (q - pp) * 6 * t : t < 0.5 ? q : t < 2 / 3 ? pp + (q - pp) * (2 / 3 - t) * 6 : pp); };
    const c = [f(h + 1 / 3), f(h), f(h - 1 / 3), a];
    return c.some(Number.isNaN) ? null : c;
  }
  return null;
}
const colourOf = (tokens, value) => {
  const r = resolve(tokens, value);
  return r === null ? null : parseColour(r);
};
const over = (fg, bg) => [0, 1, 2].map((i) => fg[i] * fg[3] + bg[i] * (1 - fg[3]));
const lum = (rgb) => {
  const [r, g, b] = rgb.slice(0, 3).map((c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
export const contrast = (a, b) => {
  const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
};
const colourProps = (tokens) => Object.keys(tokens).filter((k) => colourOf(tokens, tokens[k]) !== null);

// ============================================================ W06-AC-1: the tokens and the themes
test('W06-AC-1 style.css declares its colours as custom properties on :root, and the pinned names are among them', () => {
  const names = colourProps(LIGHT);
  for (const n of ['--bg', '--surface', '--border', '--text', '--muted', '--link', '--accent', '--warn', '--held']) {
    assert.ok(names.includes(n), `${n} is a colour custom property on :root (colour properties: ${names.length})`);
  }
  for (const s of [...STATES, 'other']) assert.ok(names.includes(`--state-${s}`), `--state-${s} is a colour custom property on :root`);
});

test('W06-AC-1 the dark block (@media (prefers-color-scheme: dark)) redefines every colour property of :root, and no other', () => {
  assert.ok(RULES.some(isDark), 'a @media (prefers-color-scheme: dark) block with rules');
  assert.ok(RULES.some((r) => isDark(r) && isRoot(r)), 'a :root rule in the dark block');
  const light = colourProps(LIGHT).sort();
  const dark = colourProps(DARK_ONLY).sort();
  assert.deepEqual(dark.filter((n) => !light.includes(n)), [], 'the dark block defines no colour that :root does not');
  assert.deepEqual(light.filter((n) => !dark.includes(n)), [], 'every colour of :root is redefined in the dark block');
  for (const n of ['--bg', '--text', '--surface']) {
    assert.notEqual(resolve(DARK, DARK[n] ?? ''), resolve(LIGHT, LIGHT[n] ?? ''), `${n} differs between the themes`);
  }
});

test('W06-AC-1 no colour literal appears in style.css outside the custom-property declarations of :root (light and dark)', () => {
  const found = [];
  const NOT_COLOUR = new Set(['font', 'font-family', 'content', 'color-scheme', 'animation', 'animation-name', 'transition', 'transition-property', 'grid-template-areas', 'will-change']);
  const scan = (rules, where) => {
    for (const r of rules) {
      for (const [k, v] of Object.entries(r.decls)) {
        if (isRoot(r) && k.startsWith('--')) continue;
        if (NOT_COLOUR.has(k)) { for (const l of literalsIn(v, false)) found.push(`${where} ${r.selectors[0]} { ${k}: ${l} }`); continue; }
        for (const l of literalsIn(v, true)) found.push(`${where} ${r.selectors[0]} { ${k}: ${l} }`);
      }
    }
  };
  scan(RULES, 'rule');
  // what cssRules does not list: the bodies of @keyframes (and any other at-rule), and anything outside :root blocks as text
  const text = CSS.replace(/\/\*[\s\S]*?\*\//g, '');
  for (const m of text.matchAll(/@keyframes\s+[\w-]+\s*\{/g)) {
    let depth = 1, i = m.index + m[0].length;
    const start = i;
    for (; i < text.length && depth > 0; i++) depth += text[i] === '{' ? 1 : text[i] === '}' ? -1 : 0;
    scan(cssRules(text.slice(start, i - 1)), '@keyframes');
  }
  const noRoot = text.replace(/:root\s*\{[^}]*\}/g, ' ');
  for (const l of literalsIn(noRoot, false)) found.push(`text ${l}`);
  assert.deepEqual([...new Set(found)], [], `colour literals outside the :root declarations: ${[...new Set(found)].slice(0, 6).join(' | ')}`);
});

// every html string that the views, the explorer and app.js render from the fixture
async function renderedHtml() {
  const views = await import('../views.js');
  const { renderExplorer } = await import('../explorer/view.js');
  const fx = loadFixture();
  const data = { manifest: fx.manifest, files: fx.files };
  const ctx = { now: fx.manifest.seen * 1000 + 60000, lastSuccess: fx.manifest.seen * 1000 + 60000 };
  const out = {};
  const add = (k, html) => { out[k] = html; };
  add('repos', views.renderRepos(data, ctx));
  add('throttle', views.renderThrottle(data, ctx));
  add('activity', views.renderActivity(data, ctx));
  for (const [k, r] of Object.entries(fx.files)) {
    if (!k.startsWith('repo.')) continue;
    add(`${r.repo} view`, views.renderRepo(data, { ...ctx, repo: r.repo }));
    add(`${r.repo} explorer`, renderExplorer(r, { node: null, tracks: null, states: null }));
    for (const n of r.nodes) {
      add(`${r.repo} ${n.id} selected`, views.renderRepo(data, { ...ctx, repo: r.repo, view: { node: n.id, tracks: null, states: null } }));
      add(`${r.repo} ${n.id} explorer`, renderExplorer(r, { node: n.id, tracks: null, states: null }));
    }
  }
  const d = clone(data);
  const a = Object.values(d.files).find((f) => f && f.repo === 'acme/alpha');
  a.running = true; a.stop = true;
  d.files['throttle.json'].held = false;
  d.files['throttle.json'].windows[1].utilization = null;
  add('running+stop alpha', views.renderRepo(d, { ...ctx, repo: 'acme/alpha' }));
  add('repos running', views.renderRepos(d, ctx));
  add('throttle open', views.renderThrottle(d, ctx));
  add('stale', views.renderRepos(data, { ...ctx, lastSuccess: ctx.now - 10 * 60000, notice: 'backing off until 12:00' }));
  const m = await makeApp();
  await m.a.start();
  for (const h of ['#/', '#/throttle', '#/activity', '#/activity?repo=acme/bravo', '#/repo/acme/alpha', '#/repo/acme/alpha?node=S01', '#/nope']) {
    m.location.hash = h;
    add(`app ${h}`, m.a.render());
  }
  const none = await makeApp({ search: '' });
  await none.a.start();
  add('app help', none.a.render());
  return out;
}

test('W06-AC-1 no colour literal appears in the HTML that the views, the explorer and app.js render from the fixture', async () => {
  const pages = await renderedHtml();
  assert.ok(Object.keys(pages).length > 20, 'many pages rendered');
  const bad = [];
  for (const [label, html] of Object.entries(pages)) for (const l of new Set(colourLiterals(html))) bad.push(`${label}: ${l}`);
  assert.deepEqual(bad, [], `colour literals in the markup: ${bad.slice(0, 6).join(' | ')}`);
});

// a state's colour in a piece of markup: the elements' own style / fill / data-color, or a style.css rule keyed on [data-state="x"] (or [data-badge="x"])
const stateVars = (els) => els.flatMap((e) => [e.attrs.style, e.attrs.fill, e.attrs['data-color']].filter(Boolean).flatMap((v) => [...v.matchAll(/var\(\s*(--state-[\w-]+)\s*[,)]/g)].map((m) => m[1])));
const ruleVars = (state) => RULES.filter((r) => r.selectors.some((s) => s.includes(`[data-state="${state}"]`) || s.includes(`[data-badge="${state}"]`) || s.includes(`.state-${state}`)))
  .flatMap((r) => Object.values(r.decls).flatMap((v) => [...v.matchAll(/var\(\s*(--state-[\w-]+)\s*[,)]/g)].map((m) => m[1])));

test('W06-AC-1 for each state present in the fixture the explorer node fill, its legend colour, the node table badge and the bar segment name the same --state-<state>', async () => {
  const views = await import('../views.js');
  const { renderExplorer } = await import('../explorer/view.js');
  const fx = loadFixture();
  const data = { manifest: fx.manifest, files: fx.files };
  const ctx = { now: fx.manifest.seen * 1000 + 60000, lastSuccess: fx.manifest.seen * 1000 + 60000 };
  const present = new Set();
  const seenIn = { explorer: new Set(), legend: new Set(), badge: new Set(), segment: new Set() };
  const cards = parse(views.renderRepos(data, ctx));
  for (const r of Object.values(fx.files).filter((f) => f && f.repo)) {
    for (const n of r.nodes) present.add(n.state);
    const expl = parse(renderExplorer(r, { node: null, tracks: null, states: null }));
    const rows = parse(views.renderRepo(data, { ...ctx, repo: r.repo }));
    const card = by(cards, 'data-card', r.repo)[0];
    for (const s of new Set(r.nodes.map((n) => n.state))) {
      const want = `--state-${s}`;
      const only = (label, vars) => assert.ok(vars.includes(want) && vars.every((v) => v === want), `${r.repo} ${s}: the ${label} names ${want} (names: ${vars.join(', ') || 'none'})`);
      const box = all(expl, (e) => e.tag === 'g' && 'data-node' in e.attrs && e.attrs['data-state'] === s && e.attrs['data-ghost'] !== 'added')[0];
      assert.ok(box, `${r.repo} ${s}: an explorer node`);
      only('explorer node fill', [...stateVars(all(box, (e) => e.tag === 'rect' && /\bbox\b/.test(e.attrs.class || ''))), ...ruleVars(s)]);
      seenIn.explorer.add(s);
      const leg = by(expl, 'data-legend', s)[0];
      assert.ok(leg, `${r.repo} ${s}: a legend entry`);
      only('legend colour', [...stateVars(selfAndDesc(leg))]);
      seenIn.legend.add(s);
      const row = all(rows, (e) => e.tag === 'tr' && 'data-node' in e.attrs && selfAndDesc(e).some((x) => x.attrs['data-badge'] === s))[0];
      assert.ok(row, `${r.repo} ${s}: a node table row with a ${s} badge`);
      const b = selfAndDesc(row).find((x) => x.attrs['data-badge'] === s);
      only('node table badge', [...stateVars(selfAndDesc(b)), ...ruleVars(s)]);
      seenIn.badge.add(s);
      const seg = selfAndDesc(card).find((x) => new RegExp(`^\\d+ ${s}$`).test(x.attrs.title || ''));
      assert.ok(seg, `${r.repo} ${s}: a bar segment`);
      only('bar segment', [...stateVars([seg]), ...ruleVars(s)]);
      seenIn.segment.add(s);
    }
  }
  assert.ok(present.size >= 5, `the fixture has several states (${[...present].join(', ')})`);
});

test('W06-AC-1 a state outside the ten takes --state-other in the explorer, the legend, the badge and the bar', async () => {
  const views = await import('../views.js');
  const { renderExplorer } = await import('../explorer/view.js');
  const fx = loadFixture();
  const d = clone({ manifest: fx.manifest, files: fx.files });
  const r = Object.values(d.files).find((f) => f && f.repo === 'acme/bravo');
  r.nodes[0].state = 'strange';
  const ctx = { now: fx.manifest.seen * 1000 + 60000, lastSuccess: fx.manifest.seen * 1000 + 60000 };
  const expl = parse(renderExplorer(r, { node: null, tracks: null, states: null }));
  const rows = parse(views.renderRepo(d, { ...ctx, repo: 'acme/bravo' }));
  const card = by(parse(views.renderRepos(d, ctx)), 'data-card', 'acme/bravo')[0];
  const box = all(expl, (e) => e.tag === 'g' && e.attrs['data-state'] === 'strange')[0];
  const leg = by(expl, 'data-legend', 'strange')[0];
  const badge = all(rows, (e) => e.attrs['data-badge'] === 'strange')[0];
  const seg = selfAndDesc(card).find((x) => /^1 strange$/.test(x.attrs.title || ''));
  for (const [label, els] of [['node', selfAndDesc(box || expl)], ['legend', selfAndDesc(leg || expl)], ['badge', selfAndDesc(badge || rows)], ['segment', [seg || card]]]) {
    assert.ok(box && leg && badge && seg, 'the four elements exist');
    const vars = stateVars(els);
    assert.ok(vars.includes('--state-other') && vars.every((v) => v === '--state-other'), `${label} names --state-other (names: ${vars.join(', ') || 'none'})`);
  }
});

// ============================================================ W06-AC-2: contrast
function pairs(tokens) {
  const out = [];
  const bad = [];
  const tok = (n) => {
    const c = tokens[n] === undefined ? null : colourOf(tokens, tokens[n]);
    if (!c) bad.push(`${n} is not a colour (${tokens[n]})`);
    return c;
  };
  const bg = tok('--bg');
  const flat = (c, base) => (c && base ? over(c, base) : null);
  const add = (label, fg, back, base = bg) => {
    if (!fg || !back || !base) return;
    const b = back[3] < 1 ? over(back, base) : back;
    out.push({ label, ratio: contrast(flat(fg, b), b) });
  };
  const surfaces = Object.keys(tokens).filter((k) => /^--surface(-[\w-]+)?$/.test(k));
  if (!surfaces.includes('--surface')) bad.push('--surface is missing');
  for (const t of ['--text', '--muted']) {
    add(`${t} on --bg`, tok(t), bg);
    for (const s of surfaces) add(`${t} on ${s}`, tok(t), tok(s));
  }
  add('--link on --bg', tok('--link'), bg);
  add('--warn on --bg', tok('--warn'), bg);
  add('--held on --bg', tok('--held'), bg);
  if (tokens['--selected'] !== undefined) add('--text on --selected', tok('--text'), tok('--selected'));
  const states = Object.keys(tokens).filter((k) => /^--state-/.test(k));
  const single = (v) => { const m = /^var\(\s*(--[\w-]+)\s*\)$/.exec(String(v || '').trim()); return m ? m[1] : null; };
  // the explorer's node label: the fill of the [data-node] text rule
  const labelRules = RULES.filter((r) => r.selectors.some((s) => /\[data-node\][^,]*\btext\b/.test(s) && !/ghost/.test(s)) && r.decls.fill !== undefined);
  if (labelRules.length === 0) bad.push('no rule fills the explorer\'s node label ([data-node] text { fill: var(--...) })');
  for (const r of labelRules) {
    const t = single(r.decls.fill);
    if (!t) { bad.push(`the node label fill is not a single var(): ${r.decls.fill}`); continue; }
    for (const s of states) add(`node label ${t} on ${s}`, tok(t), tok(s));
  }
  // badges and every other rule that sets a text colour and a background colour from tokens
  let badgeRules = 0;
  for (const r of RULES) {
    if (r.media.some((m) => /prefers-color-scheme/.test(m))) continue;
    const c = single(r.decls.color);
    const b = single(r.decls.background) || single(r.decls['background-color']);
    const isBadge = r.selectors.some((s) => /\.badge|\[data-badge/.test(s));
    if (isBadge) badgeRules++;
    if (!c) continue;
    if (b) add(`${r.selectors[0]}: ${c} on ${b}`, tok(c), tok(b));
    else if (isBadge && r.selectors.some((s) => /\[style\]/.test(s))) for (const s of states) add(`${r.selectors[0]}: badge ${c} on ${s}`, tok(c), tok(s));
  }
  if (badgeRules === 0) bad.push('no rule styles a .badge / [data-badge]');
  return { out, bad, states };
}

for (const [theme, tokens] of [['light', LIGHT], ['dark', DARK]]) {
  test(`W06-AC-2 in the ${theme} theme every pair of change 2 has a contrast ratio of at least 4.5:1`, () => {
    const { out, bad, states } = pairs(tokens);
    assert.deepEqual(bad, [], `the pairs can be built: ${bad.join(' | ')}`);
    assert.ok(states.length >= 11, `${states.length} --state-* tokens`);
    assert.ok(out.length >= 6 + 2 * 2 + 11, `enough pairs were checked (${out.length})`);
    const low = out.filter((p) => !(p.ratio >= 4.5)).map((p) => `${p.label} ${p.ratio.toFixed(2)}`);
    assert.deepEqual(low, [], `${theme}: pairs below 4.5:1: ${low.join(' | ')}`);
  });
}

test('W06-AC-2 the contrast computation is WCAG 2: black on white is 21:1, #777 on white 4.48:1, an alpha is composited', () => {
  const r = (a, b) => contrast(parseColour(a), parseColour(b));
  assert.ok(Math.abs(r('#000', '#fff') - 21) < 1e-9);
  assert.ok(Math.abs(r('#777777', '#ffffff') - 4.478) < 0.01);
  assert.ok(Math.abs(r('#fff', '#000') - 21) < 1e-9);
  assert.deepEqual(parseColour('rgba(0, 0, 0, 0.5)'), [0, 0, 0, 0.5]);
  assert.ok(Math.abs(contrast(over(parseColour('rgba(0,0,0,0.5)'), [255, 255, 255]), [255, 255, 255]) - 3.95) < 0.05);
  assert.equal(resolve({ '--a': 'var(--b)', '--b': '#123456' }, 'var(--a)'), '#123456', 'var() chains are followed');
});
