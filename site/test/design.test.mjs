// W06 (site-design), the structure: W06-AC-3 (the shell and the page head), W06-AC-4 (repository cards),
// W06-AC-5 (throttle meters and chart), W06-AC-6 (activity timeline and badges), W06-AC-8 (narrow layout and table
// wrappers), W06-AC-9 (nothing else changes). The colour tokens, contrast and the change mark (W06-AC-1, 2, 7) are
// the second slice's, in the same file or in site/test/design-*.test.mjs.
//
// Rendered from W03's fixture (helper.mjs), parsed with dom.mjs. Markup the node spec leaves open is not pinned: a
// card is the element with data-card="<owner>/<name>"; a badge is an element with data-badge="<value>"; a bar segment
// is an element inside a card with title="<count> <state>" and a width in its style; a date heading is an h3-h6 in the
// events section holding the date as YYYY-MM-DD (or an element with a datetime of that day); an event is an <li> (or an
// element with data-event) of that section; the shell is the one <header> of the view.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { parse, all, one, by } from './dom.mjs';
import { loadFixture } from './helper.mjs';
import { MIN, readSite, cssRules, cssImports, selfAndDesc, withAncestors, hasAncestor, classes, colourLiterals, makeApp } from './design-helper.mjs';

const clone = (x) => JSON.parse(JSON.stringify(x));
const repoFile = (data, name) => Object.values(data.files).find((f) => f && f.repo === name);
async function setup() {
  const views = await import('../views.js');
  const fx = loadFixture();
  const data = { manifest: fx.manifest, files: fx.files };
  const ctx = { now: fx.manifest.seen * 1000 + MIN, lastSuccess: fx.manifest.seen * 1000 + MIN };
  return { views, fx, data, ctx };
}
const renderAll = (views, data, ctx) => ({
  repos: views.renderRepos(data, ctx), throttle: views.renderThrottle(data, ctx), activity: views.renderActivity(data, ctx),
  'activity?repo': views.renderActivity(data, { ...ctx, repo: 'acme/bravo' }),
  alpha: views.renderRepo(data, { ...ctx, repo: 'acme/alpha' }), bravo: views.renderRepo(data, { ...ctx, repo: 'acme/bravo' }),
  selected: views.renderRepo(data, { ...ctx, repo: 'acme/alpha', view: { node: 'S01', tracks: null, states: null } }),
  missing: views.renderRepo(data, { ...ctx, repo: 'acme/unknown' }),
});
const badgeValues = (el) => selfAndDesc(el).filter((e) => 'data-badge' in e.attrs).map((e) => e.attrs['data-badge']);
const sectionOf = (root, name) => {
  const s = one(root, (e) => e.attrs['data-section'] === name);
  assert.ok(s, `a <section data-section="${name}">`);
  return s;
};

// ============================================================ W06-AC-3: the shell and the page head
const ROUTES = [
  ['', 'repos', '#/'], ['#/', 'repos', '#/'], ['#/throttle', 'throttle', '#/throttle'], ['#/activity', 'activity', '#/activity'],
  ['#/activity?repo=acme/bravo', 'activity', '#/activity'], ['#/repo/acme/alpha', 'repo', '#/'], ['#/repo/acme/bravo', 'repo', '#/'],
  ['#/no/such/route', 'not-found', null],
];
const NAV_HREFS = ['#/', '#/throttle', '#/activity'];

function shellOf(html, label, { pill = true } = {}) {
  const root = parse(html);
  const headers = all(root, (e) => e.tag === 'header');
  assert.equal(headers.length, 1, `${label}: one <header>`);
  const [header] = headers;
  const view = one(root, (e) => 'data-view' in e.attrs);
  assert.ok(view, `${label}: a data-view root`);
  assert.ok(selfAndDesc(view).includes(header), `${label}: the header is inside the view's root`);
  const navs = all(header, (e) => e.tag === 'nav');
  assert.equal(navs.length, 1, `${label}: one <nav> in the header`);
  const links = all(navs[0], (e) => e.tag === 'a');
  assert.deepEqual(links.map((a) => a.attrs.href), NAV_HREFS, `${label}: the navigation links`);
  const pills = by(header, 'data-live');
  if (pill) assert.equal(pills.length, 1, `${label}: the age pill (data-live) is in the header`);
  let rest = header.text.replace(navs[0].text, '');
  for (const p of pills) rest = rest.replace(p.text, '');
  assert.ok(rest.trim().length > 0, `${label}: the header holds the site's name besides the navigation and the age`);
  return { root, header, nav: navs[0], links, pill: pills[0], view };
}

test('W06-AC-3 every route (#/, #/throttle, #/activity, #/repo/<owner>/<name>, an unknown one) renders inside the shell: one header with the name, the navigation and the age pill', async () => {
  const { a, location } = await makeApp();
  await a.start();
  for (const [hash, name] of ROUTES) {
    location.hash = hash;
    const html = a.render();
    const s = shellOf(html, hash || '(empty)');
    assert.ok(html.includes(`data-view="${name}"`), `${hash}: data-view="${name}"`);
    const first = all(s.view, (e) => e.tag === 'header' || e.tag === 'h1')[0];
    if (name !== 'not-found') assert.equal(first.tag, 'header', `${hash}: the header comes before the view's heading`);
  }
});

test('W06-AC-3 the setup help renders inside the shell\'s header too, and still says how to set the gist', async () => {
  const { a } = await makeApp({ search: '' });
  await a.start();
  const html = a.render();
  const s = shellOf(html, 'setup help', { pill: false });
  assert.equal(s.view.attrs['data-view'], 'setup');
  assert.ok(html.includes('?gist=') && html.includes('config.json'));
  assert.ok(by(s.root, 'aria-current', 'page').length <= 1);
});

test('W06-AC-3 exactly the current route\'s navigation link has aria-current="page" (the repositories link on a repository\'s page, none on an unknown route)', async () => {
  const { a, location } = await makeApp();
  await a.start();
  for (const [hash, , current] of ROUTES) {
    location.hash = hash;
    const s = shellOf(a.render(), hash || '(empty)');
    const marked = by(s.root, 'aria-current', 'page');
    assert.equal(marked.length, current === null ? 0 : 1, `${hash || '(empty)'}: ${current === null ? 'no' : 'one'} aria-current="page"`);
    for (const l of s.links) {
      assert.equal(l.attrs['aria-current'] === 'page', l.attrs.href === current, `${hash || '(empty)'}: ${l.attrs.href} ${l.attrs.href === current ? 'is' : 'is not'} current`);
    }
  }
});

test('W06-AC-3 the age pill has data-live="fresh" while the data is not stale, data-live="stale" and the word stale when it is, and keeps W03\'s age texts', async () => {
  const { a, clk, fx, location } = await makeApp();
  await a.start(); // a 200 at seen + 1 min
  const live = (hash) => {
    location.hash = hash;
    const html = a.render();
    const s = shellOf(html, hash || '(empty)');
    const entry = withAncestors(s.root, (e) => e === s.pill)[0];
    const stale = [s.pill, ...entry.parents].map((e) => e.attrs['data-stale']).find((v) => v !== undefined);
    return { s, stale };
  };
  for (const hash of ['#/', '#/throttle', '#/activity', '#/repo/acme/alpha', '#/nope']) {
    const { s, stale } = live(hash);
    assert.equal(stale, 'false', `${hash}: data-stale="false"`);
    assert.equal(s.pill.attrs['data-live'], 'fresh', `${hash}: data-live="fresh"`);
    assert.doesNotMatch(s.pill.text, /\bstale\b/i, `${hash}: no "stale" in a fresh pill`);
    assert.ok(s.pill.text.includes('updated 1 minutes ago'), `${hash}: updated 1 minutes ago`);
    assert.ok(s.pill.text.includes('seen 1 minutes ago'), `${hash}: seen 1 minutes ago`);
  }
  clk.advance(5 * MIN + 1000); // the last request is over 5 minutes old; seen is still fresh
  assert.ok(fx.manifest.seen * 1000 + 20 * MIN > clk.now());
  for (const hash of ['#/', '#/throttle', '#/activity', '#/repo/acme/alpha', '#/nope']) {
    const { s, stale } = live(hash);
    assert.equal(stale, 'true', `${hash}: data-stale="true"`);
    assert.equal(s.pill.attrs['data-live'], 'stale', `${hash}: data-live="stale"`);
    assert.match(s.pill.text, /\bstale\b/, `${hash}: the word stale`);
    assert.ok(s.pill.text.includes('updated 6 minutes ago') && s.pill.text.includes('seen 6 minutes ago'), `${hash}: W03's age texts`);
  }
});

test('W06-AC-3 index.html has a theme-color meta for each colour scheme, a data: favicon and its viewport meta, and neither it nor style.css names another origin', () => {
  const htmlText = readSite('index.html');
  const root = parse(htmlText);
  const metas = all(root, (e) => e.tag === 'meta');
  const themes = metas.filter((m) => m.attrs.name === 'theme-color');
  assert.equal(themes.length, 2, 'two theme-color metas');
  assert.ok(themes.every((m) => m.attrs.content), 'each has a content');
  assert.equal(themes.filter((m) => /prefers-color-scheme:\s*light/.test(m.attrs.media || '')).length, 1, 'one for light');
  assert.equal(themes.filter((m) => /prefers-color-scheme:\s*dark/.test(m.attrs.media || '')).length, 1, 'one for dark');
  const icons = all(root, (e) => e.tag === 'link' && /\bicon\b/.test(e.attrs.rel || ''));
  assert.ok(icons.length >= 1 && icons.every((l) => /^data:/.test(l.attrs.href || '')), 'a favicon whose href is a data: URI');
  const vp = metas.find((m) => m.attrs.name === 'viewport');
  assert.ok(vp && /width=device-width/.test(vp.attrs.content), 'the viewport meta');
  // no other origin: no src or href, @import or url() of an http(s) or protocol-relative URL
  const foreign = (v) => /^\s*(?:["']?)(?:[a-z][a-z0-9+.-]*:)?\/\//i.test(v) && !/^\s*["']?data:/i.test(v);
  for (const el of all(root, () => true)) {
    for (const k of ['src', 'href']) {
      if (el.attrs[k] === undefined) continue;
      assert.ok(!foreign(el.attrs[k]), `index.html <${el.tag} ${k}="${el.attrs[k].slice(0, 40)}"> is not another origin`);
    }
  }
  const css = readSite('style.css');
  for (const target of cssImports(css)) assert.ok(!foreign(target.replace(/^url\(/i, '')), `@import ${target}`);
  for (const m of `${css}\n${htmlText}`.matchAll(/url\(\s*([^)]*)\)/gi)) {
    assert.ok(!foreign(m[1]), `url(${m[1].slice(0, 40)}) is not another origin`);
  }
});

// ============================================================ W06-AC-4: repository cards
test('W06-AC-4 each repository has one card linking to #/repo/<owner>/<name> with its loop state badge and "<merged> of <total> merged"', async () => {
  const { views, data, ctx } = await setup();
  const root = parse(views.renderRepos(data, ctx));
  const names = Object.values(data.files).filter((f) => f && f.repo).map((f) => f.repo).sort();
  assert.deepEqual(names, ['acme/alpha', 'acme/bravo']);
  assert.deepEqual(by(root, 'data-card').map((c) => c.attrs['data-card']).sort(), names, 'one card per repository');
  for (const name of names) {
    const r = repoFile(data, name);
    const card = by(root, 'data-card', name)[0];
    assert.ok(card, `${name}: a card (data-card)`);
    const links = selfAndDesc(card).filter((e) => e.tag === 'a' && e.attrs.href === `#/repo/${name}`);
    assert.equal(links.length, 1, `${name}: one link to its page`);
    const merged = r.nodes.filter((n) => n.state === 'merged').length;
    assert.ok(card.text.includes(`${merged} of ${r.nodes.length} merged`), `${name}: "${merged} of ${r.nodes.length} merged" (text: ${card.text.slice(0, 80)})`);
    assert.ok(badgeValues(card).includes('idle'), `${name}: the loop state "idle" is a badge`);
    assert.ok(selfAndDesc(card).some((e) => e.attrs['data-badge'] === 'idle' && e.text === 'idle'), `${name}: the badge reads idle`);
  }
});

test('W06-AC-4 the loop state badge of a card reads running, or STOP requested', async () => {
  const { views, data, ctx } = await setup();
  const d = clone(data);
  repoFile(d, 'acme/alpha').running = true;
  repoFile(d, 'acme/bravo').stop = true;
  const root = parse(views.renderRepos(d, ctx));
  const alpha = by(root, 'data-card', 'acme/alpha')[0], bravo = by(root, 'data-card', 'acme/bravo')[0];
  assert.ok(alpha && bravo, 'a card (data-card) per repository');
  assert.ok(selfAndDesc(alpha).some((e) => e.attrs['data-badge'] === 'running' && e.text === 'running'), 'running');
  assert.ok(selfAndDesc(bravo).some((e) => 'data-badge' in e.attrs && /stop/i.test(e.attrs['data-badge']) && /STOP requested/i.test(e.text)), 'STOP requested');
});

test('W06-AC-4 a card has one bar segment per state present, its width the state\'s share of the nodes to 0.1% and its title "<count> <state>"', async () => {
  const { views, data, ctx } = await setup();
  const root = parse(views.renderRepos(data, ctx));
  for (const name of ['acme/alpha', 'acme/bravo']) {
    const r = repoFile(data, name);
    const card = by(root, 'data-card', name)[0];
    assert.ok(card, `${name}: a card (data-card)`);
    const counts = {};
    for (const n of r.nodes) counts[n.state] = (counts[n.state] || 0) + 1;
    const segs = selfAndDesc(card).filter((e) => /^\d+ \S/.test(e.attrs.title || ''));
    assert.equal(segs.length, Object.keys(counts).length, `${name}: one segment per state present`);
    const got = {};
    for (const s of segs) {
      const [, c, st] = /^(\d+) (.+)$/.exec(s.attrs.title);
      assert.ok(!(st in got), `${name}: one segment of ${st}`);
      got[st] = Number(c);
      const w = /(?:^|;|\s)width\s*:\s*(\d+(?:\.\d+)?)%/.exec(s.attrs.style || '');
      assert.ok(w, `${name}: ${st} has a percentage width in its style (${s.attrs.style})`);
      assert.match(w[1], /^\d+(\.\d)?$/, `${name}: ${st} width to one decimal`);
      assert.ok(Math.abs(Number(w[1]) - (100 * counts[st]) / r.nodes.length) <= 0.05 + 1e-9, `${name}: ${st} width ${w[1]}% is ${counts[st]}/${r.nodes.length}`);
    }
    assert.deepEqual(got, counts, `${name}: the titles give each state's count`);
  }
});

test('W06-AC-4 a repository with no nodes has "no nodes" and no bar segment', async () => {
  const { views, data, ctx } = await setup();
  const d = clone(data);
  repoFile(d, 'acme/bravo').nodes = [];
  const root = parse(views.renderRepos(d, ctx));
  const bravo = by(root, 'data-card', 'acme/bravo')[0];
  assert.ok(bravo, 'the card of the empty repository');
  assert.ok(bravo.text.includes('no nodes'), 'says no nodes');
  assert.equal(selfAndDesc(bravo).filter((e) => /^\d+ \S/.test(e.attrs.title || '')).length, 0, 'no segment');
  const alpha = by(root, 'data-card', 'acme/alpha')[0];
  assert.ok(!alpha.text.includes('no nodes'), 'a repository with nodes does not say it');
});

// ============================================================ W06-AC-5: throttle
const isMeter = (e) => e.tag === 'meter' || e.attrs.role === 'meter';
const meterRatio = (m) => {
  if (m.tag === 'meter') return Number(m.attrs.value) / (m.attrs.max === undefined ? 1 : Number(m.attrs.max));
  return Number(m.attrs['aria-valuenow']) / (m.attrs['aria-valuemax'] === undefined ? 100 : Number(m.attrs['aria-valuemax']));
};
// the window's container: the largest element naming this window and no other
function windowBox(root, name, others) {
  const els = all(root, (e) => e.text.includes(name) && others.every((o) => !e.text.includes(o)) && e.tag !== 'svg');
  assert.ok(els.length, `an element for the window ${name}`);
  return els.reduce((best, e) => (e.text.length > best.text.length ? e : best));
}
const utcText = (s) => { const i = new Date(s * 1000).toISOString(); return `${i.slice(0, 10)} ${i.slice(11, 16)} UTC`; };

test('W06-AC-5 each window with a utilization has a meter at that value and its percentage; one without has n/a and no meter', async () => {
  const { views, data, ctx } = await setup();
  const thr = data.files['throttle.json'];
  const [w1, w2] = thr.windows.map((w) => w.name);
  const root = parse(views.renderThrottle(data, ctx));
  const meters = all(root, isMeter);
  assert.equal(meters.length, 2, 'one meter per window');
  thr.windows.forEach((w, i) => {
    assert.ok(Math.abs(meterRatio(meters[i]) - w.utilization) < 0.005, `${w.name}: meter at ${w.utilization} (got ${meterRatio(meters[i])})`);
    const box = windowBox(root, w.name, thr.windows.filter((x) => x !== w).map((x) => x.name));
    assert.ok(selfAndDesc(box).includes(meters[i]), `${w.name}: its meter is in its box`);
    assert.match(box.text, new RegExp(`\\b${Math.round(w.utilization * 100)}\\s?%`), `${w.name}: the percentage`);
    assert.ok(box.text.includes(utcText(w.resets_at)), `${w.name}: W03's UTC reset time`);
  });
  const d = clone(data);
  d.files['throttle.json'].windows[1].utilization = null;
  const r2 = parse(views.renderThrottle(d, ctx));
  assert.equal(all(r2, isMeter).length, 1, 'one meter when one window has no utilization');
  const box = windowBox(r2, w2, [w1]);
  assert.ok(box.text.includes('n/a'), `${w2}: n/a`);
  assert.equal(all(box, isMeter).length, 0, `${w2}: no meter`);
  assert.equal(all(windowBox(r2, w1, [w2]), isMeter).length, 1, `${w1}: still its meter`);
});

test('W06-AC-5 with a fake clock a reset 2 h 10 min ahead reads "resets in 2 h 10 min" and one 7 min ahead "resets in 7 min", next to W03\'s UTC time', async () => {
  const { views, data, ctx } = await setup();
  const d = clone(data);
  const nowS = ctx.now / 1000;
  const [a, b] = d.files['throttle.json'].windows;
  a.resets_at = nowS + 130 * 60;
  b.resets_at = nowS + 7 * 60;
  const check = (c, ta, tb, label) => {
    const root = parse(views.renderThrottle(d, c));
    const ba = windowBox(root, a.name, [b.name]), bb = windowBox(root, b.name, [a.name]);
    assert.ok(ba.text.includes(ta), `${label}: ${a.name} reads "${ta}" (text: ${ba.text.slice(0, 120)})`);
    assert.ok(bb.text.includes(tb), `${label}: ${b.name} reads "${tb}" (text: ${bb.text.slice(0, 120)})`);
    assert.ok(!bb.text.includes(' h '), `${label}: under an hour is minutes only`);
    assert.ok(ba.text.includes(utcText(a.resets_at)) && bb.text.includes(utcText(b.resets_at)), `${label}: W03's UTC time stays`);
  };
  check(ctx, 'resets in 2 h 10 min', 'resets in 7 min', 'now');
  check({ ...ctx, now: ctx.now + MIN }, 'resets in 2 h 9 min', 'resets in 6 min', 'one minute later (no request)');
});

test('W06-AC-5 held and open are badges, held with the reason', async () => {
  const { views, data, ctx } = await setup();
  const thr = data.files['throttle.json'];
  const held = parse(views.renderThrottle(data, ctx));
  const box = one(held, (e) => e.attrs['data-held'] === 'true');
  assert.ok(box, 'data-held="true" stays');
  const badge = selfAndDesc(box).find((e) => e.attrs['data-badge'] === 'held');
  assert.ok(badge, 'a data-badge="held" in it');
  assert.ok(box.text.includes(thr.reason), 'the reason is in it');
  assert.ok(/held/.test(badge.text), 'the badge reads held');
  const d = clone(data);
  d.files['throttle.json'].held = false;
  d.files['throttle.json'].reason = null;
  const open = parse(views.renderThrottle(d, ctx));
  const obox = one(open, (e) => e.attrs['data-held'] === 'false');
  assert.ok(obox, 'data-held="false" stays');
  assert.ok(selfAndDesc(obox).some((e) => e.attrs['data-badge'] === 'open' && /open/.test(e.text)), 'a data-badge="open" reading open');
  assert.equal(by(open, 'data-badge', 'held').length, 0, 'no held badge when open');
});

test('W06-AC-5 the view has one SVG holding the history line, a filled area and grid lines labelled 0%, 50% and 100%', async () => {
  const { views, data, ctx } = await setup();
  const html = views.renderThrottle(data, ctx);
  assert.equal((html.match(/<svg\b/g) || []).length, 1, 'one svg');
  const svg = one(parse(html), (e) => e.tag === 'svg');
  const thr = data.files['throttle.json'];
  const line = one(svg, (e) => e.tag === 'polyline');
  assert.ok(line && line.attrs.points.trim().split(/\s+/).length === thr.history.length, 'the history line, one point per sample');
  const area = all(svg, (e) => (e.tag === 'polygon' || e.tag === 'path') && ((e.attrs.fill !== undefined && e.attrs.fill !== 'none') || /area/.test(e.attrs.class || '')));
  assert.ok(area.length >= 1, 'a filled area (a <polygon> or <path> with a fill) under the line');
  const lines = all(svg, (e) => e.tag === 'line' && e.attrs.y1 !== undefined && e.attrs.y1 === e.attrs.y2);
  assert.ok(new Set(lines.map((l) => l.attrs.y1)).size >= 3, 'three horizontal grid lines');
  const labels = all(svg, (e) => e.tag === 'text').map((t) => t.text);
  for (const l of ['0%', '50%', '100%']) assert.ok(labels.includes(l), `a grid label ${l} (labels: ${labels.join(' | ')})`);
  const ys = (l) => Number(all(svg, (e) => e.tag === 'text' && e.text === l)[0].attrs.y);
  assert.ok(ys('100%') < ys('50%') && ys('50%') < ys('0%'), '100% above 50% above 0%');
});

// ============================================================ W06-AC-6: activity, repository, explorer
const dayOf = (ev) => ev.time.slice(0, 10);
function timeline(root) {
  const sec = sectionOf(root, 'events');
  const mark = (e) => /^h[3-6]$/.test(e.tag) || e.tag === 'li' || 'data-event' in e.attrs;
  const seq = all(sec, mark);
  const hasEvAttr = seq.some((e) => 'data-event' in e.attrs);
  const groups = [];
  for (const e of seq) {
    if (/^h[3-6]$/.test(e.tag)) groups.push({ heading: e, events: [] });
    else if (e.tag === 'li' ? !hasEvAttr : true) {
      assert.ok(groups.length, 'an event comes after a date heading');
      groups.at(-1).events.push(e);
    }
  }
  return groups;
}
const headingDate = (h) => {
  const m = /\d{4}-\d{2}-\d{2}/.exec(h.text);
  if (m) return m[0];
  const t = selfAndDesc(h).map((e) => e.attrs.datetime).find((v) => v);
  return t ? t.slice(0, 10) : null;
};

test('W06-AC-6 the activity view has one date heading per day of the events, newest first, each followed by exactly that day\'s events in W03\'s order', async () => {
  const { views, data, ctx } = await setup();
  const d = clone(data);
  const evs = d.files['activity.json'].events;
  evs.unshift({ repo: 'acme/bravo', text: 'bravo on the next day', time: '2026-11-02T00:00:01Z' });
  evs.push({ repo: 'acme/alpha', text: 'late in October', time: '2026-10-31T23:59:59Z' });
  evs.push({ repo: 'acme/alpha', text: 'early in October', time: '2026-10-31T08:00:00Z' });
  const run = (dd, c, label) => {
    const act = dd.files['activity.json'].events.filter((v) => !c.repo || v.repo === c.repo);
    const days = [...new Set(act.map(dayOf))];
    const groups = timeline(parse(views.renderActivity(dd, c)));
    assert.deepEqual(groups.map((g) => headingDate(g.heading)), days, `${label}: one heading per day, newest first`);
    groups.forEach((g, i) => {
      const want = act.filter((v) => dayOf(v) === days[i]);
      assert.equal(g.events.length, want.length, `${label}: ${days[i]} has exactly its ${want.length} events`);
      want.forEach((v, j) => {
        assert.ok(g.events[j].text.includes(v.text) && g.events[j].text.includes(v.repo), `${label}: ${days[i]} #${j} is "${v.text}" (got ${g.events[j].text.slice(0, 60)})`);
      });
    });
  };
  run(d, ctx, 'three days');
  assert.equal(timeline(parse(views.renderActivity(d, ctx))).length, 3);
  run(d, { ...ctx, repo: 'acme/bravo' }, 'filtered to bravo');
  run(data, ctx, 'the fixture (one day)');
  assert.equal(timeline(parse(views.renderActivity(data, ctx))).length, 1, 'the fixture\'s events fall on one day: one heading');
});

test('W06-AC-6 the current repository filter of the activity view has aria-current="true"', async () => {
  const { views, data, ctx } = await setup();
  const cur = (c) => by(parse(views.renderActivity(data, c)), 'aria-current', 'true');
  assert.deepEqual(cur(ctx).map((a) => a.attrs.href), ['#/activity'], 'no filter: "all" is current');
  assert.deepEqual(cur({ ...ctx, repo: 'acme/bravo' }).map((a) => a.attrs.href), ['#/activity?repo=acme/bravo'], 'bravo is current');
  assert.deepEqual(cur({ ...ctx, repo: 'acme/alpha' }).map((a) => a.attrs.href), ['#/activity?repo=acme/alpha'], 'alpha is current');
});

test('W06-AC-6 each mergeable state, triage state, loop state and STOP state is an element with data-badge naming it', async () => {
  const { views, data, ctx } = await setup();
  const act = parse(views.renderActivity(data, ctx));
  const inSection = (root, name) => selfAndDesc(sectionOf(root, name)).filter((e) => 'data-badge' in e.attrs);
  for (const [value, el] of [['MERGEABLE', 'prs'], ['CONFLICTING', 'prs'], ['question', 'triage'], ['answered', 'triage']]) {
    const b = inSection(act, el).find((e) => e.attrs['data-badge'] === value);
    assert.ok(b, `${el}: data-badge="${value}"`);
    assert.ok(b.text.includes(value), `${el}: the badge ${value} reads ${value}`);
  }
  const repo = parse(views.renderRepo(data, { ...ctx, repo: 'acme/alpha' }));
  assert.ok(inSection(repo, 'prs').some((e) => e.attrs['data-badge'] === 'MERGEABLE') && inSection(repo, 'prs').some((e) => e.attrs['data-badge'] === 'CONFLICTING'), 'the repository view\'s PRs');
  assert.ok(by(repo, 'data-badge', 'idle').length >= 1, 'the repository view\'s loop state idle');
  const d = clone(data);
  repoFile(d, 'acme/alpha').running = true;
  repoFile(d, 'acme/alpha').stop = true;
  const r2 = parse(views.renderRepo(d, { ...ctx, repo: 'acme/alpha' }));
  assert.ok(by(r2, 'data-badge', 'running').length >= 1, 'the loop state running');
  const stop = all(r2, (e) => 'data-badge' in e.attrs && /stop/i.test(e.attrs['data-badge']));
  assert.ok(stop.length >= 1, 'a data-badge naming STOP');
  assert.ok(stop.some((e) => /requested/i.test(e.text)), 'the STOP badge says requested');
});

// the colour of a badge: a var(--state-<state>) in its inline style or fill, or in a rule of style.css for it
function badgeNamesState(el, state, rules) {
  const tok = `var(--state-${state})`;
  const inline = selfAndDesc(el).some((e) => (e.attrs.style || '').includes(tok) || (e.attrs.fill || '').includes(tok));
  if (inline) return true;
  return rules.some((r) => Object.values(r.decls).some((v) => v.includes(tok)) &&
    r.selectors.some((s) => s.includes(`[data-badge="${state}"]`) || s.includes(`[data-state="${state}"]`) || s.includes(`.state-${state}`)));
}

test('W06-AC-6 each node table row\'s state is a badge in its --state-<state> colour', async () => {
  const { views, data, ctx } = await setup();
  const rules = cssRules(readSite('style.css'));
  const root = parse(views.renderRepo(data, { ...ctx, repo: 'acme/alpha' }));
  const r = repoFile(data, 'acme/alpha');
  for (const n of r.nodes) {
    const row = one(root, (e) => e.tag === 'tr' && e.attrs['data-node'] === n.id);
    assert.ok(row, `row ${n.id}`);
    const badge = selfAndDesc(row).find((e) => e.attrs['data-badge'] === n.state && e.text === n.state);
    assert.ok(badge, `${n.id}: its state ${n.state} is a data-badge="${n.state}" element`);
    assert.ok(badgeNamesState(badge, n.state, rules), `${n.id}: the badge takes var(--state-${n.state})`);
    assert.ok(row.text.includes(n.track) && row.text.includes(String(n.starts)), `${n.id}: W03's other cells stay`);
  }
  const f01 = one(root, (e) => e.tag === 'tr' && e.attrs['data-node'] === 'F01');
  assert.ok(f01.text.includes('gave up:'), 'the details follow the badge');
});

test('W06-AC-6 the explorer\'s SVG and details panel use no colour literal', async () => {
  const { fx } = await setup();
  const { renderExplorer } = await import('../explorer/view.js');
  let seen = 0;
  for (const [k, r] of Object.entries(fx.files)) {
    if (!k.startsWith('repo.')) continue;
    for (const node of [null, ...r.nodes.map((n) => n.id)]) {
      const html = renderExplorer(r, { node, tracks: null, states: null });
      const root = parse(html);
      if (node === null) assert.ok(all(root, (e) => e.tag === 'rect').length >= 1, `${r.repo}: boxes are drawn`);
      else assert.ok(by(root, 'data-panel', node).length === 1, `${r.repo} ${node}: the details panel`);
      const lit = colourLiterals(html);
      assert.deepEqual(lit, [], `${r.repo} ${node ?? '(none selected)'}: no colour literal, found ${[...new Set(lit)].slice(0, 6).join(', ')}`);
      seen++;
    }
  }
  assert.ok(seen >= 3);
});

// ============================================================ W06-AC-8: narrow screens
test('W06-AC-8 style.css has a max-width: 40rem media query that wraps the navigation, makes the cards one column and puts the details panel under the drawing', () => {
  const rules = cssRules(readSite('style.css'));
  const narrow = rules.filter((r) => r.media.some((m) => /\(\s*max-width\s*:\s*40rem\s*\)/.test(m)));
  assert.ok(narrow.length > 0, 'a @media (max-width: 40rem) block with rules');
  const inRule = (re, ok) => narrow.some((r) => r.selectors.some((s) => re.test(s)) && ok(r.decls));
  assert.ok(inRule(/nav|header/i, (d) => d['flex-wrap'] === 'wrap'), 'the header / navigation wraps (flex-wrap: wrap)');
  const stacked = (d) => /^(1fr|minmax\(0,\s*1fr\)|none|100%|repeat\(1,\s*1fr\))$/.test(d['grid-template-columns'] || '') ||
    d['flex-direction'] === 'column' || d.display === 'block';
  assert.ok(inRule(/card/i, stacked), 'the cards are one column');
  assert.ok(inRule(/aside|panel|explorer/i, (d) => stacked(d) || d.float === 'none' || d.position === 'static'), 'the details panel goes under the drawing');
});

test('W06-AC-8 every <table> in every view rendered from the fixture is inside an element of class table-scroll whose rule sets overflow-x: auto', async () => {
  const { views, data, ctx } = await setup();
  const rules = cssRules(readSite('style.css'));
  assert.ok(rules.some((r) => r.selectors.some((s) => /(^|[\s>+~,])(?:[a-z]*)\.table-scroll\b/.test(s) && !/:/.test(s.replace(/\.table-scroll/, ''))) && r.decls['overflow-x'] === 'auto'),
    'a .table-scroll rule with overflow-x: auto');
  let tables = 0;
  for (const [label, html] of Object.entries(renderAll(views, data, ctx))) {
    for (const t of withAncestors(parse(html), (e) => e.tag === 'table')) {
      tables++;
      assert.ok(hasAncestor(t, (p) => classes(p).includes('table-scroll')), `${label}: a <table> is inside a .table-scroll`);
    }
  }
  const { a, location } = await makeApp();
  await a.start();
  for (const hash of ['#/', '#/throttle', '#/activity', '#/repo/acme/alpha', '#/nope']) {
    location.hash = hash;
    for (const t of withAncestors(parse(a.render()), (e) => e.tag === 'table')) {
      tables++;
      assert.ok(hasAncestor(t, (p) => classes(p).includes('table-scroll')), `${hash}: a <table> is inside a .table-scroll`);
    }
  }
  assert.ok(tables >= 4, `the fixture's views have tables (${tables})`);
  const only = withAncestors(parse(views.renderRepo(data, { ...ctx, repo: 'acme/alpha' })), (e) => e.tag === 'table');
  assert.ok(only.length >= 1 && only.every((t) => hasAncestor(t, (p) => classes(p).includes('table-scroll'))), 'the node table is wrapped');
});

// ============================================================ W06-AC-9: nothing else changes
test('W06-AC-9 site/package.json has no dependencies or devDependencies', () => {
  const pkg = JSON.parse(readSite('package.json'));
  for (const k of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies']) assert.ok(!(k in pkg), `no ${k}`);
});

// .github/workflows/pages.yml is byte-identical to main's at the node base (6147b74d534d2c9e962d6833068c8e55ed092fa4).
// CI checks out one commit (no history), so `git show <base>:...` is not available there: the base's content is
// recorded as its SHA-256 instead (git show 6147b74:.github/workflows/pages.yml | sha256sum).
test('W06-AC-9 .github/workflows/pages.yml is byte-identical to the node base\'s', () => {
  const sha = createHash('sha256').update(readFileSync(new URL('../../.github/workflows/pages.yml', import.meta.url))).digest('hex');
  assert.equal(sha, '3e14cadbab011675baab88c594644626dfd0b477eaba6e0ddb11873dd2558a9e');
});
