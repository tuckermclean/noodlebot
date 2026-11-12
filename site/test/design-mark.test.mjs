// W06 (site-design), the second slice, the change mark: W06-AC-7.
//
// Data A is W03's fixture; data B is a deep copy of it with (1) one new event of acme/bravo, (2) the state of one node
// of acme/alpha (R01) changed (held to failed), which also changes alpha's counts (the one repository whose card
// is marked). What the page marks is read from the HTML of createApp's render(), as mount()'s draw() reads it, with a
// fake fetch and a fake clock (as app.test.mjs does): data-new="true" is the mark, on
//   - the event (the <li> or element holding its time, repository and text, nothing larger),
//   - the node table row (tr[data-node="R01"]) and the explorer box (the [data-node="R01"] group of the SVG),
//   - the card ([data-card="acme/alpha"]).
// The test pins no name of ctx (the previous data and the time it was replaced come in through it): it checks the
// outcome of the whole page, and that rendering is deterministic.
import test from 'node:test';
import assert from 'node:assert/strict';
import { parse, all, by } from './dom.mjs';
import { loadFixture, clock, fakeFetch } from './helper.mjs';
import { MIN, readSite, cssRules } from './design-helper.mjs';

const clone = (x) => JSON.parse(JSON.stringify(x));
const NEW_EVENT = { repo: 'acme/bravo', text: 'bravo brand new event', time: '2026-11-01T10:02:00Z' };

// A and B as gist answers; the fetch answers 304 to the ETag of the current one
function datasets() {
  const fx = loadFixture();
  const A = fx.gist;
  const B = clone(A);
  const edit = (name, fn) => { const j = JSON.parse(B.files[name].content); fn(j); B.files[name].content = JSON.stringify(j); };
  edit('activity.json', (j) => j.events.unshift(clone(NEW_EVENT)));
  edit('repo.acme.alpha.json', (j) => { j.nodes.find((n) => n.id === 'R01').state = 'failed'; });
  return { fx, A, B };
}

async function scenario(first = 'A') {
  const { createApp } = await import('../app.js');
  const { fx, A, B } = datasets();
  const clk = clock(fx.manifest.seen * 1000 + MIN);
  const cur = { body: first === 'A' ? A : B, etag: first === 'A' ? '"A"' : '"B"' };
  const f = fakeFetch((c) => {
    if (!c.url.startsWith('https://api.github.com/gists/')) return { status: 404, body: '' };
    if (c.headers.get('If-None-Match') === cur.etag) return { status: 304, headers: { ETag: cur.etag } };
    return { status: 200, headers: { ETag: cur.etag }, body: cur.body };
  }, clk);
  const location = { search: '?gist=g1', hash: '' };
  const a = createApp({ location, fetch: f, now: clk.now, hidden: clk.hidden });
  const publish = (which) => { cur.body = which === 'A' ? A : B; cur.etag = which === 'A' ? '"A"' : '"B"'; };
  // the page's second: tick, then draw (render) the route
  const draw = async (hash) => { location.hash = hash; return a.render(); };
  return { a, clk, f, location, publish, draw, fx };
}

const ROUTES = ['#/', '#/throttle', '#/activity', '#/activity?repo=acme/bravo', '#/activity?repo=acme/alpha', '#/repo/acme/alpha',
  '#/repo/acme/alpha?node=R01', '#/repo/acme/bravo', '#/nope'];
const marked = (html) => by(parse(html), 'data-new', 'true');
const anyNew = (html) => by(parse(html), 'data-new');
// every route of the page: [route, [marked elements]]
async function sweep(s) {
  const out = {};
  for (const r of ROUTES) out[r] = await s.draw(r);
  return out;
}
const none = (pages, label) => {
  for (const [r, html] of Object.entries(pages)) assert.equal(anyNew(html).length, 0, `${label}: nothing is marked on ${r} (found ${anyNew(html).map((e) => e.tag).join(',')})`);
};
// exactly the marks of data B
function onlyB(pages, label) {
  const m = (r) => marked(pages[r]);
  for (const r of ROUTES) {
    assert.equal(anyNew(pages[r]).length, marked(pages[r]).length, `${label} ${r}: every data-new is "true"`);
  }
  const card = m('#/');
  assert.equal(card.length, 1, `${label}: one mark on #/ (the card)`);
  assert.equal(card[0].attrs['data-card'], 'acme/alpha', `${label}: it is acme/alpha's card`);
  assert.equal(m('#/throttle').length, 0, `${label}: nothing on #/throttle`);
  for (const r of ['#/activity', '#/activity?repo=acme/bravo']) {
    const ev = m(r);
    assert.equal(ev.length, 1, `${label}: one mark on ${r} (the new event)`);
    assert.ok(ev[0].text.includes(NEW_EVENT.text) && ev[0].text.includes(NEW_EVENT.repo), `${label} ${r}: it is the new event (${ev[0].tag}: ${ev[0].text.slice(0, 60)})`);
    assert.ok(!ev[0].text.includes('bravo newest event'), `${label} ${r}: the mark is on the event alone, not on a container`);
  }
  assert.equal(m('#/activity?repo=acme/alpha').length, 0, `${label}: nothing on alpha's activity (the event is bravo's)`);
  for (const r of ['#/repo/acme/alpha', '#/repo/acme/alpha?node=R01']) {
    const got = m(r);
    assert.equal(got.length, 2, `${label}: two marks on ${r}: the row and the box (got ${got.map((e) => `${e.tag}[${e.attrs['data-node'] || ''}]`).join(' ')})`);
    assert.ok(got.every((e) => e.attrs['data-node'] === 'R01'), `${label} ${r}: both are node R01`);
    assert.deepEqual(got.map((e) => e.tag).sort(), ['g', 'tr'], `${label} ${r}: the table row and the explorer box`);
  }
  assert.equal(m('#/repo/acme/bravo').length, 0, `${label}: nothing on bravo's page`);
  assert.equal(m('#/nope').length, 0, `${label}: nothing on an unknown route`);
}

test('W06-AC-7 after the first data nothing is marked, on any route', async () => {
  const s = await scenario('A');
  await s.a.start();
  none(await sweep(s), 'first data');
  s.clk.advance(MIN);
  await s.a.tick(); // a 304
  none(await sweep(s), 'after a 304 of the first data');
});

test('W06-AC-7 data B marks exactly the new event, the changed node\'s table row and explorer box, and the changed repository\'s card', async () => {
  const s = await scenario('A');
  await s.a.start();
  await sweep(s); // the page draws data A
  s.publish('B');
  s.clk.advance(MIN);
  assert.equal(await s.a.tick(), true, 'a request is made 60 s later');
  const pages = await sweep(s);
  assert.ok(pages['#/'].includes('data-card="acme/alpha"'), 'data B is shown');
  assert.ok(pages['#/activity'].includes(NEW_EVENT.text), 'the new event is shown');
  onlyB(pages, 'B');
});

test('W06-AC-7 a 304 after B changes no mark, and 2 minutes after B arrived nothing is marked', async () => {
  const s = await scenario('A');
  await s.a.start();
  await sweep(s);
  s.publish('B');
  s.clk.advance(MIN);
  await s.a.tick(); // B arrives now
  onlyB(await sweep(s), 'B arrived');
  s.clk.advance(30 * 1000);
  onlyB(await sweep(s), '30 s after B (no request)');
  s.clk.advance(30 * 1000);
  assert.equal(await s.a.tick(), true, 'the next request 60 s after B');
  assert.equal(s.f.api().at(-1).headers.get('If-None-Match'), '"B"');
  onlyB(await sweep(s), 'a 304, 60 s after B');
  s.clk.advance(59 * 1000);
  onlyB(await sweep(s), '119 s after B');
  s.clk.advance(1000);
  await s.a.tick(); // a 304 at 120 s
  none(await sweep(s), '2 minutes after B');
  s.clk.advance(MIN);
  await s.a.tick();
  none(await sweep(s), '3 minutes after B');
});

test('W06-AC-7 the page that loads data B first (a reload) marks nothing; the marks do not depend on the route drawn first', async () => {
  const s = await scenario('B');
  await s.a.start();
  none(await sweep(s), 'a reload on B');
  const t = await scenario('A');
  await t.a.start();
  await t.draw('#/throttle'); // only one route was drawn while A was current
  t.publish('B');
  t.clk.advance(MIN);
  await t.a.tick();
  onlyB(await sweep(t), 'B, after drawing only #/throttle first');
});

test('W06-AC-7 an unchanged poll (a 304) marks nothing, and a loop state change marks the repository\'s card alone', async () => {
  const s = await scenario('A');
  await s.a.start();
  await sweep(s);
  s.publish('A');
  s.clk.advance(MIN);
  await s.a.tick(); // 304: A again
  none(await sweep(s), 'same data');
  // a new gist answer whose bravo repo started running: its card (and no row, box or event) is marked
  const { createApp } = await import('../app.js');
  const fx = loadFixture();
  const A = fx.gist, B = clone(A);
  const j = JSON.parse(B.files['repo.acme.bravo.json'].content);
  j.running = true;
  B.files['repo.acme.bravo.json'].content = JSON.stringify(j);
  const clk = clock(fx.manifest.seen * 1000 + MIN);
  let cur = { body: A, etag: '"1"' };
  const f = fakeFetch((c) => (c.headers.get('If-None-Match') === cur.etag ? { status: 304 } : { status: 200, headers: { ETag: cur.etag }, body: cur.body }), clk);
  const location = { search: '?gist=g1', hash: '#/' };
  const a = createApp({ location, fetch: f, now: clk.now, hidden: clk.hidden });
  await a.start();
  a.render();
  cur = { body: B, etag: '"2"' };
  clk.advance(MIN);
  await a.tick();
  const cards = marked(a.render());
  assert.deepEqual(cards.map((e) => e.attrs['data-card']), ['acme/bravo'], 'the bravo card is marked');
  location.hash = '#/repo/acme/bravo';
  assert.equal(marked(a.render()).length, 0, 'no row or box of bravo is marked');
  location.hash = '#/repo/acme/alpha';
  assert.equal(marked(a.render()).length, 0, 'alpha is untouched');
});

test('W06-AC-7 rendering is deterministic: the same state at the same time gives the same HTML (the views stay pure)', async () => {
  const s = await scenario('A');
  await s.a.start();
  await sweep(s);
  s.publish('B');
  s.clk.advance(MIN);
  await s.a.tick();
  const one = await sweep(s), two = await sweep(s);
  assert.deepEqual(one, two);
  const views = await import('../views.js');
  const fx = loadFixture();
  const data = { manifest: fx.manifest, files: fx.files };
  const ctx = { now: fx.manifest.seen * 1000 + MIN, lastSuccess: fx.manifest.seen * 1000 + MIN };
  assert.equal(views.renderRepos(data, ctx), views.renderRepos(data, { ...ctx }), 'same ctx, same HTML');
  assert.equal(anyNew(views.renderRepos(data, ctx)).length + anyNew(views.renderActivity(data, ctx)).length, 0, 'a ctx without a previous data marks nothing');
});

// ---- style.css
const RULES = cssRules(readSite('style.css'));
const marks = (r) => r.selectors.some((s) => /\[data-new\b/.test(s));
const animates = (r) => ['animation', 'animation-name'].some((k) => r.decls[k] !== undefined && !/^\s*none\b/.test(r.decls[k]));
const NO_PREF = /\(\s*prefers-reduced-motion\s*:\s*no-preference\s*\)/;

test('W06-AC-7 style.css animates [data-new="true"] only inside @media (prefers-reduced-motion: no-preference), and outside it the mark is a static outline', () => {
  const rules = RULES.filter(marks);
  assert.ok(rules.length > 0, 'style.css has [data-new="true"] rules');
  const animated = rules.filter(animates);
  assert.ok(animated.length > 0, 'an animation for [data-new="true"]');
  for (const r of animated) assert.ok(r.media.some((m) => NO_PREF.test(m)), `${r.selectors[0]}'s animation is inside @media (prefers-reduced-motion: no-preference) (media: ${r.media.join(' ') || 'none'})`);
  for (const r of rules.filter((x) => !x.media.some((m) => NO_PREF.test(m)))) assert.ok(!animates(r), `${r.selectors[0]} outside the media query does not animate`);
  const css = readSite('style.css').replace(/\/\*[\s\S]*?\*\//g, '');
  for (const r of animated) {
    const name = /^\s*([\w-]+)/.exec(r.decls['animation-name'] ?? r.decls.animation.replace(/^[^\w-]*/, ''))?.[1];
    const names = [...String(r.decls['animation-name'] ?? r.decls.animation).matchAll(/[A-Za-z_][\w-]*/g)].map((m) => m[0]);
    assert.ok(names.some((n) => new RegExp(`@keyframes\\s+${n}\\b`).test(css)) || name === undefined, `an @keyframes for the animation (${names.join(', ')})`);
  }
  const outlined = rules.filter((r) => !r.media.some((m) => NO_PREF.test(m)) && !animates(r) && /\[data-new="true"\]/.test(r.selectors.join(',')) &&
    ['outline', 'outline-style', 'outline-width'].some((k) => r.decls[k] !== undefined && !/^\s*(none|0)\b/.test(r.decls[k])));
  assert.ok(outlined.length > 0, 'a [data-new="true"] rule outside the motion media query with an outline and no animation');
});
