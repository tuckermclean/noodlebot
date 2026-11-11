// W03-AC-1 (escaping), W03-AC-4 and W03-AC-5: the views of site/views.js, pure functions from data to an HTML
// string, rendered from the fixture data (built by site.py from scheduler/testdata/site, see helper.mjs).
// Each test imports the module itself, so a missing module fails each case on its own line.
//
// Expected from the implementation:
//   site/views.js   an ES module of pure functions, no DOM, no clock of its own
//     export escapeHtml(s) -> string      escapes & < > " ' ; non-strings are turned into strings first
//     export ageText(seconds, nowMs) -> string
//         "<n> minutes ago", n = whole minutes between the epoch-seconds value and nowMs (floor, never negative)
//     export isStale({seen, lastSuccess, now}) -> boolean
//         seen = the manifest's `seen` (epoch seconds), lastSuccess and now in ms. True exactly when
//         now - seen*1000 > 20 minutes, or lastSuccess is null, or now - lastSuccess > 5 minutes.
//     data = {manifest, files} as poller.state.data (files keyed by gist file name: 'throttle.json',
//     'activity.json', 'repo.<owner>.<name>.json'); ctx = {now (ms), lastSuccess (ms or null), ...} per view:
//     export renderRepos(data, ctx)     the default route: a link href="#/repo/<owner>/<name>" per repository
//     export renderThrottle(data, ctx)
//     export renderActivity(data, ctx)  ctx.repo: '<owner>/<name>' filters the events (only)
//     export renderRepo(data, ctx)      ctx.repo: '<owner>/<name>'; ctx.sort: 'id'|'name'|'track'|'state'|'deps'|
//                                       'starts' (default order: the data's), ctx.dir: 'asc' (default) | 'desc'
//     Every one returns a root element carrying data-view="repos|throttle|activity|repo" and
//     data-stale="true|false" (isStale of the data's manifest.seen, ctx.lastSuccess and ctx.now), and shows
//     "updated <ageText>" and "seen <ageText>" (the manifest's updated and seen) as text.
//     Throttle: a window per entry of throttle.windows (its name, utilization as "<n>%", reset time as
//       "YYYY-MM-DD HH:MM UTC"), data-held="true|false" on the root and the word "held" with the reason, or the
//       word "open" (and not "held"), and an inline <svg> with one <polyline points="x,y x,y ..."> of the history
//       and <text> axis labels of its first and last time as "HH:MM" UTC.
//     Activity: <section data-section="events|prs|triage|deploys">: events newest first (the data's order is
//       newest first: it is displayed as given, only the repository filter applies), every repository's open PRs
//       with their mergeable state, the triage issues with state and link, the deploys (version, previous,
//       rejected, events).
//     Repo: <section data-section="prs"> of the open PRs; <table data-table="nodes"> with <th data-sort="<column>">
//       headers and one <tr data-node="<ID>"> per node, cells in the order id, name, track, state (+ details: the
//       text, the PR, the issue, the mergeable state, waiting_for), deps, starts.
//     Links: https://github.com/<owner>/<name>/pull/<n>, .../issues/<n>, .../blob/main/nodes/<ID>-<name>.md
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadFixture } from './helper.mjs';

const MIN = 60000;
const text = (html) => html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ');
const hrefs = (html) => [...html.matchAll(/href="([^"]*)"/g)].map((m) => m[1].replace(/&amp;/g, '&'));
const section = (html, name) => {
  const m = html.match(new RegExp(`<section[^>]*data-section="${name}"[^>]*>([\\s\\S]*?)</section>`));
  assert.ok(m, `a <section data-section="${name}">`);
  return m[1];
};
const clone = (x) => JSON.parse(JSON.stringify(x));

async function setup() {
  const views = await import('../views.js');
  const fx = loadFixture();
  const data = { manifest: fx.manifest, files: fx.files };
  const ctx = { now: fx.manifest.seen * 1000 + MIN, lastSuccess: fx.manifest.seen * 1000 + MIN };
  return { views, fx, data, ctx };
}
const rows = (html) => [...html.matchAll(/<tr[^>]*data-node="([^"]*)"/g)].map((m) => m[1]);

// ---- W03-AC-1: escaping in every view
test('W03-AC-1 escapeHtml escapes & < > " and \'', async () => {
  const { escapeHtml } = await import('../views.js');
  assert.equal(escapeHtml('<script>alert(1)</script>'), '&lt;script&gt;alert(1)&lt;/script&gt;');
  assert.equal(escapeHtml('a"b'), 'a&quot;b');
  assert.equal(escapeHtml('a&b'), 'a&amp;b');
  assert.ok(!escapeHtml("it's").includes("'"));
});

test('W03-AC-1 a text from the data holding <script> or " is shown escaped in the activity, repository and throttle views', async () => {
  const { views, fx, data, ctx } = await setup();
  const X = fx.hostile.script;
  const html = {
    activity: views.renderActivity(data, ctx),
    alpha: views.renderRepo(data, { ...ctx, repo: 'acme/alpha' }),
  };
  for (const [name, h] of Object.entries(html)) {
    assert.ok(!h.includes(X), `${name}: no raw ${X}`);
    assert.doesNotMatch(h, /<script/i, `${name}: no <script tag`);
    assert.ok(h.includes('&lt;script&gt;alert(1)&lt;/script&gt;'), `${name}: the planted text, escaped`);
    assert.ok(h.includes('&quot;'), `${name}: the quote, escaped`);
  }
  assert.ok(html.activity.includes('event with &lt;script&gt;alert(1)&lt;/script&gt; and a &quot; quote'), 'the event line');
  assert.ok(html.activity.includes('Triage asks &lt;script&gt;alert(1)&lt;/script&gt; &quot;'), 'the triage question');
  assert.ok(html.alpha.includes('gave up: &lt;script&gt;alert(1)&lt;/script&gt; and &quot;'), 'the failure of a node');
  assert.ok(html.alpha.includes('node/P01-&lt;script&gt;alert(1)&lt;/script&gt;&quot;'), 'the branch of a PR');
  // the same texts in the places the throttle and repositories views show: reason, window status, repository name
  const d2 = clone(data);
  d2.files['throttle.json'].reason = `${X} and "`;
  d2.files['throttle.json'].windows[0].status = `${X}"`;
  d2.files['repo.acme.alpha.json'].repo = `acme/${X}"`;
  const th = views.renderThrottle(d2, ctx);
  assert.doesNotMatch(th, /<script/i);
  assert.ok(th.includes('&lt;script&gt;alert(1)&lt;/script&gt; and &quot;'), 'the throttle reason, escaped');
  const rp = views.renderRepos(d2, ctx);
  assert.doesNotMatch(rp, /<script/i);
  assert.ok(!rp.includes('"><'), 'no attribute is broken out of by a quote');
  assert.ok(rp.includes('&lt;script&gt;'), 'the repository name, escaped');
  for (const h of [th, rp, views.renderActivity(d2, ctx), views.renderRepo(d2, { ...ctx, repo: `acme/${X}"` })]) {
    assert.doesNotMatch(h, /<script/i);
  }
});

// ---- W03-AC-4
test('W03-AC-4 ageText gives whole minutes: "<n> minutes ago"', async () => {
  const { ageText } = await import('../views.js');
  const s = 1700001000;
  assert.equal(ageText(s, s * 1000 + 5 * MIN), '5 minutes ago');
  assert.equal(ageText(s, s * 1000 + 5 * MIN + 59000), '5 minutes ago');
  assert.equal(ageText(s, s * 1000 + 90 * MIN), '90 minutes ago');
  assert.equal(ageText(s, s * 1000 + 3 * MIN), '3 minutes ago');
});

test('W03-AC-4 isStale is true exactly when seen is over 20 minutes old or the last success over 5 minutes old', async () => {
  const { isStale } = await import('../views.js');
  const seen = 1700001000, S = seen * 1000;
  const c = (age, last) => isStale({ seen, now: S + age, lastSuccess: S + age - last });
  assert.equal(c(10 * MIN, MIN), false, 'fresh');
  assert.equal(c(20 * MIN, MIN), false, 'seen exactly 20 minutes old');
  assert.equal(c(20 * MIN + 1000, MIN), true, 'seen over 20 minutes old');
  assert.equal(c(21 * MIN, 0), true, 'seen over 20 minutes old, success now');
  assert.equal(c(10 * MIN, 5 * MIN), false, 'success exactly 5 minutes old');
  assert.equal(c(10 * MIN, 5 * MIN + 1000), true, 'success over 5 minutes old');
  assert.equal(c(10 * MIN, 30 * MIN), true, 'success long ago');
  assert.equal(isStale({ seen, now: S + MIN, lastSuccess: null }), true, 'no successful request');
});

test('W03-AC-4 every view shows the manifest updated and seen as ages', async () => {
  const { views, data, ctx } = await setup();
  const d = clone(data);
  d.manifest.updated = d.manifest.seen - 120;
  const c = { ...ctx, now: d.manifest.seen * 1000 + 8 * MIN, lastSuccess: d.manifest.seen * 1000 + 8 * MIN };
  const all = {
    repos: views.renderRepos(d, c), throttle: views.renderThrottle(d, c), activity: views.renderActivity(d, c),
    repo: views.renderRepo(d, { ...c, repo: 'acme/alpha' }),
  };
  for (const [name, h] of Object.entries(all)) {
    const t = text(h);
    assert.ok(t.includes('updated 10 minutes ago'), `${name}: updated 10 minutes ago`);
    assert.ok(t.includes('seen 8 minutes ago'), `${name}: seen 8 minutes ago`);
    assert.ok(h.includes(`data-view="${name}"`), `${name}: data-view`);
  }
});

test('W03-AC-4 every view is marked stale exactly when seen is over 20 minutes old or the last success over 5 minutes old', async () => {
  const { views, data } = await setup();
  const S = data.manifest.seen * 1000;
  const render = {
    repos: (c) => views.renderRepos(data, c), throttle: (c) => views.renderThrottle(data, c),
    activity: (c) => views.renderActivity(data, c), repo: (c) => views.renderRepo(data, { ...c, repo: 'acme/alpha' }),
  };
  const cases = [
    [10 * MIN, 1 * MIN, 'false'], [20 * MIN, 1 * MIN, 'false'], [20 * MIN + 1000, 1 * MIN, 'true'],
    [10 * MIN, 5 * MIN, 'false'], [10 * MIN, 5 * MIN + 1000, 'true'], [30 * MIN, 30 * MIN, 'true'],
  ];
  for (const [name, r] of Object.entries(render)) {
    for (const [age, sinceOk, stale] of cases) {
      const html = r({ now: S + age, lastSuccess: S + age - sinceOk });
      assert.ok(html.includes(`data-stale="${stale}"`), `${name}: seen ${age / 1000}s, last success ${sinceOk / 1000}s ago -> data-stale="${stale}"`);
      assert.ok(!html.includes(`data-stale="${stale === 'true' ? 'false' : 'true'}"`), `${name}: one stale mark only`);
    }
  }
});

// ---- W03-AC-5: the throttle view
test('W03-AC-5 the throttle view shows both windows with utilization and reset time, held with its reason, and the history line', async () => {
  const { views, data, ctx } = await setup();
  const html = views.renderThrottle(data, ctx);
  const t = text(html);
  const thr = data.files['throttle.json'];
  const utc = (s) => { const i = new Date(s * 1000).toISOString(); return `${i.slice(0, 10)} ${i.slice(11, 16)} UTC`; };
  assert.equal(thr.windows.length, 2);
  for (const w of thr.windows) {
    assert.ok(t.includes(w.name), `the window ${w.name}`);
    assert.ok(t.includes(`${Math.round(w.utilization * 100)}%`), `${w.name}: utilization ${Math.round(w.utilization * 100)}%`);
    assert.ok(t.includes(utc(w.resets_at)), `${w.name}: reset time ${utc(w.resets_at)}`);
  }
  assert.ok(html.includes('data-held="true"'));
  assert.match(t, /\bheld\b/);
  assert.ok(t.includes(thr.reason), 'the reason');
  assert.equal((html.match(/<svg\b/g) || []).length, 1, 'one inline svg');
  const pl = html.match(/<polyline[^>]*\spoints="([^"]*)"/);
  assert.ok(pl, 'a <polyline points="...">');
  const pts = pl[1].trim().split(/\s+/);
  assert.equal(pts.length, thr.history.length, 'one point per history sample');
  assert.ok(pts.every((p) => /^-?\d+(\.\d+)?,-?\d+(\.\d+)?$/.test(p)), 'x,y pairs');
  const xs = pts.map((p) => Number(p.split(',')[0]));
  assert.ok(xs.every((x, i) => i === 0 || x > xs[i - 1]), 'time runs along x');
  const labels = [...html.matchAll(/<text[^>]*>([^<]*)<\/text>/g)].map((m) => m[1]);
  const hm = (s) => new Date(s * 1000).toISOString().slice(11, 16);
  assert.ok(labels.some((l) => l.includes(hm(thr.history[0].t))), 'the axis labels the first time');
  assert.ok(labels.some((l) => l.includes(hm(thr.history.at(-1).t))), 'the axis labels the last time');
});

test('W03-AC-5 the throttle view says open, without a hold reason, when the throttle does not hold', async () => {
  const { views, data, ctx } = await setup();
  const d = clone(data);
  d.files['throttle.json'].held = false;
  d.files['throttle.json'].reason = null;
  const html = views.renderThrottle(d, ctx);
  const t = text(html);
  assert.ok(html.includes('data-held="false"'));
  assert.match(t, /\bopen\b/);
  assert.doesNotMatch(t, /\bheld\b/);
  assert.ok(!t.includes('projected 95%'));
  assert.ok(views.renderThrottle(data, ctx).includes('data-held="true"'));
});

// ---- W03-AC-5: the activity view
test('W03-AC-5 the activity view shows the events newest first, and only one repository\'s when filtered', async () => {
  const { views, data, ctx } = await setup();
  const ev = data.files['activity.json'].events;
  const ev1 = section(views.renderActivity(data, ctx), 'events');
  const t = text(ev1);
  const order = ['bravo newest event', 'bravo older event', 'not deployed: make test failed on d2', 'deployed c1..d1 (version v0.1)', 'event with', 'node started'];
  const at = order.map((s) => t.indexOf(s));
  assert.ok(at.every((i) => i >= 0), 'every event is shown');
  assert.deepEqual([...at].sort((a, b) => a - b), at, 'newest first');
  assert.equal(ev.length, order.length);
  const bravo = section(views.renderActivity(data, { ...ctx, repo: 'acme/bravo' }), 'events');
  assert.ok(text(bravo).includes('bravo newest event') && text(bravo).includes('bravo older event'));
  assert.ok(!text(bravo).includes('node started') && !text(bravo).includes('deployed c1'), 'no event of acme/alpha');
  const alpha = text(section(views.renderActivity(data, { ...ctx, repo: 'acme/alpha' }), 'events'));
  assert.ok(alpha.includes('node started') && !alpha.includes('bravo'), 'only acme/alpha events');
  const nb = text(section(views.renderActivity(data, { ...ctx, repo: 'acme/alpha' }), 'events'));
  assert.ok(nb.indexOf('not deployed') < nb.indexOf('node started'), 'newest first within the filter');
});

test('W03-AC-5 the activity view shows the open PRs of every repository with their mergeable state and links', async () => {
  const { views, data, ctx } = await setup();
  const html = views.renderActivity(data, ctx);
  const prs = section(html, 'prs');
  const t = text(prs);
  assert.ok(t.includes('#51') && t.includes('MERGEABLE'), 'PR 51 and its state');
  assert.ok(t.includes('#52') && t.includes('CONFLICTING'), 'PR 52 and its state');
  assert.ok(t.includes('acme/alpha'), 'the repository of the PRs');
  const h = hrefs(prs);
  assert.ok(h.includes('https://github.com/acme/alpha/pull/51'));
  assert.ok(h.includes('https://github.com/acme/alpha/pull/52'));
});

test('W03-AC-5 the activity view shows the triage issues with state and link, and the deploys', async () => {
  const { views, data, ctx } = await setup();
  const html = views.renderActivity(data, ctx);
  const tr = section(html, 'triage');
  const tt = text(tr);
  assert.ok(tt.includes('#23') && tt.includes('question'), 'issue 23 and its state');
  assert.ok(tt.includes('#24') && tt.includes('answered'), 'issue 24 and its state');
  assert.ok(hrefs(tr).includes('https://github.com/acme/alpha/issues/23'));
  assert.ok(hrefs(tr).includes('https://github.com/acme/alpha/issues/24'));
  const dp = text(section(html, 'deploys'));
  const d = data.files['activity.json'].deploy;
  assert.ok(dp.includes(d.version), 'the deployed version');
  assert.ok(dp.includes(d.previous), 'the previous commit');
  for (const r of d.rejected) assert.ok(dp.includes(r), 'a rejected commit');
  for (const e of d.events) assert.ok(dp.includes(e.text), `the deploy event ${e.text}`);
});

// ---- W03-AC-5: the repository view
test('W03-AC-5 the repository view shows every node with its state and details', async () => {
  const { views, data, ctx } = await setup();
  const repo = data.files['repo.acme.alpha.json'];
  const html = views.renderRepo(data, { ...ctx, repo: 'acme/alpha' });
  assert.deepEqual([...rows(html)].sort(), repo.nodes.map((n) => n.id).sort(), 'one row per node');
  const row = (id) => {
    const m = html.match(new RegExp(`<tr[^>]*data-node="${id}"[^>]*>([\\s\\S]*?)</tr>`));
    assert.ok(m, `row ${id}`);
    return m[1];
  };
  for (const n of repo.nodes) {
    const r = row(n.id), t = text(r);
    assert.ok(t.includes(n.id) && t.includes(n.name) && t.includes(n.track), `${n.id}: id, name, track`);
    assert.ok(t.includes(n.state), `${n.id}: state ${n.state}`);
    for (const d of n.deps) assert.ok(t.includes(d), `${n.id}: dep ${d}`);
    assert.ok(t.includes(String(n.starts)), `${n.id}: starts`);
  }
  assert.ok(text(row('F01')).includes('gave up:'), 'F01 shows its failure text');
  assert.ok(hrefs(row('Q01')).includes('https://github.com/acme/alpha/issues/12'), 'Q01 links its issue');
  assert.ok(hrefs(row('S01')).includes('https://github.com/acme/alpha/pull/51'), 'S01 links its PR');
  assert.ok(hrefs(row('P01')).includes('https://github.com/acme/alpha/pull/52') && text(row('P01')).includes('CONFLICTING'), 'P01: PR and mergeable state');
  assert.ok(text(row('Y01')).includes('M02'), 'Y01 shows what it waits for');
  assert.ok(text(row('M01')).includes('merged'));
});

test('W03-AC-5 the repository view sorts by every column, ascending and descending', async () => {
  const { views, data, ctx } = await setup();
  const repo = data.files['repo.acme.alpha.json'];
  const byId = Object.fromEntries(repo.nodes.map((n) => [n.id, n]));
  const key = {
    id: (n) => n.id, name: (n) => n.name, track: (n) => n.track, state: (n) => n.state,
    deps: (n) => n.deps.join(','), starts: (n) => n.starts,
  };
  const h0 = views.renderRepo(data, { ...ctx, repo: 'acme/alpha' });
  for (const col of Object.keys(key)) assert.ok(new RegExp(`<th[^>]*data-sort="${col}"`).test(h0), `header of ${col} is sortable`);
  for (const col of Object.keys(key)) {
    for (const dir of ['asc', 'desc']) {
      const html = views.renderRepo(data, { ...ctx, repo: 'acme/alpha', sort: col, dir });
      const ids = rows(html);
      assert.equal(ids.length, repo.nodes.length, `${col} ${dir}: every node`);
      const ks = ids.map((id) => key[col](byId[id]));
      for (let i = 1; i < ks.length; i++) {
        const c = typeof ks[i] === 'number' ? ks[i - 1] - ks[i] : ks[i - 1] < ks[i] ? -1 : ks[i - 1] > ks[i] ? 1 : 0;
        assert.ok(dir === 'asc' ? c <= 0 : c >= 0, `${col} ${dir}: ${ids[i - 1]} before ${ids[i]}`);
      }
    }
  }
  const asc = rows(views.renderRepo(data, { ...ctx, repo: 'acme/alpha', sort: 'id', dir: 'asc' }));
  const desc = rows(views.renderRepo(data, { ...ctx, repo: 'acme/alpha', sort: 'id', dir: 'desc' }));
  assert.notDeepEqual(asc, desc);
  assert.equal(asc[0], 'A01');
  assert.equal(desc[0], 'Z01');
});

test('W03-AC-5 the repository view shows the open PRs', async () => {
  const { views, data, ctx } = await setup();
  const html = views.renderRepo(data, { ...ctx, repo: 'acme/alpha' });
  const prs = section(html, 'prs');
  const t = text(prs);
  assert.ok(t.includes('#51') && t.includes('MERGEABLE') && t.includes('#52') && t.includes('CONFLICTING'));
  assert.ok(hrefs(prs).includes('https://github.com/acme/alpha/pull/51'));
  assert.ok(hrefs(prs).includes('https://github.com/acme/alpha/pull/52'));
  assert.ok(!text(section(views.renderRepo(data, { ...ctx, repo: 'acme/bravo' }), 'prs')).includes('#51'), 'another repository has none of them');
});

test('W03-AC-5 every PR, issue and node link points at the GitHub URL of change 4', async () => {
  const { views, data, ctx } = await setup();
  const repo = data.files['repo.acme.alpha.json'];
  const html = views.renderRepo(data, { ...ctx, repo: 'acme/alpha' });
  const h = hrefs(html);
  for (const n of repo.nodes) {
    assert.ok(h.includes(`https://github.com/acme/alpha/blob/main/nodes/${n.id}-${n.name}.md`), `node ${n.id} links its spec`);
  }
  const gh = h.filter((x) => x.startsWith('https://github.com/'));
  const allowed = [/^https:\/\/github\.com\/acme\/alpha\/pull\/\d+$/, /^https:\/\/github\.com\/acme\/alpha\/issues\/\d+$/,
    /^https:\/\/github\.com\/acme\/alpha\/blob\/main\/nodes\/[A-Z]\d+-[a-z0-9-]+\.md$/];
  for (const x of gh) assert.ok(allowed.some((re) => re.test(x)), `${x} is a PR, issue or node URL`);
  const act = hrefs(views.renderActivity(data, ctx)).filter((x) => x.startsWith('https://github.com/'));
  assert.ok(act.length >= 4);
  for (const x of act) assert.match(x, /^https:\/\/github\.com\/acme\/(alpha|bravo)\/(pull|issues)\/\d+$/, `${x} in the activity view`);
  const bravo = hrefs(views.renderRepo(data, { ...ctx, repo: 'acme/bravo' }));
  assert.ok(bravo.includes('https://github.com/acme/bravo/blob/main/nodes/B01-' + data.files['repo.acme.bravo.json'].nodes[0].name + '.md'));
});

test('W03-AC-1 the repositories view lists each repository with a link to its route', async () => {
  const { views, data, ctx } = await setup();
  const h = hrefs(views.renderRepos(data, ctx));
  assert.ok(h.includes('#/repo/acme/alpha') && h.includes('#/repo/acme/bravo'));
  assert.ok(h.includes('#/throttle') && h.includes('#/activity'), 'the navigation');
});
