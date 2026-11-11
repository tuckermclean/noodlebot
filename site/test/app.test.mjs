// W03-AC-1 and W03-AC-4 (the page): site/app.js, with a fake fetch, a fake clock, a fake visibility and a fake
// location. Each test imports the module itself, so a missing module fails each case on its own line.
//
// Expected from the implementation (the views are documented in views.test.mjs):
//   site/app.js   an ES module that imports in Node with no DOM (it touches `document` only when present, in mount())
//     export resolveGist({search, config}) -> string | null
//         search  location.search ('' or '?gist=<id>'); config  the parsed config.json ({"gist": "<id>"}) or null.
//         The ID of `?gist=` wins over config.gist; null when neither gives a non-empty string.
//     export parseRoute(hash) -> {name, repo?}
//         name 'repos' for '', '#', '#/'; 'throttle' for '#/throttle'; 'activity' for '#/activity' (and
//         '#/activity?repo=<owner>/<name>' gives repo '<owner>/<name>'); 'repo' for '#/repo/<owner>/<name>' with
//         repo '<owner>/<name>'; 'not-found' for anything else.
//     export createApp({location, fetch, now, hidden}) -> app
//         location  a plain mutable object {search, hash}, read afresh at each render()
//         fetch     fetch(url, init) -> Response-like; now () -> ms; hidden () -> boolean
//       await app.start()   resolves the gist ID (location.search, else a fetch of the relative URL 'config.json'
//                           from the page's own host; a failed or 404 config fetch means "no ID"); with an ID it
//                           creates the poller (poll.js createPoller) as app.poller and ticks it once; with none it
//                           makes NO request to api.github.com
//       await app.tick()    app.poller.tick()
//       app.render() -> string   the HTML of the page for the current location.hash, from the poller's data, now()
//                           and poller.state.lastSuccess; with no gist ID it says how to set one, naming `?gist=`
//                           and `config.json`. Every view's root element carries data-view="<route name>" and
//                           data-stale="true|false" (see views.test.mjs); an unknown route renders data-view="not-found".
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadFixture, clock, fakeFetch } from './helper.mjs';

const MIN = 60000;
const ok = (body, etag = '"e1"') => ({ status: 200, headers: { ETag: etag }, body });
const text = (html) => html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ');

async function page({ search = '', hash = '', config, configThrows = false, start } = {}) {
  const app = await import('../app.js');
  const fx = loadFixture();
  const clk = clock(start ?? fx.manifest.seen * 1000 + MIN);
  const f = fakeFetch((c) => {
    if (c.url.startsWith('https://api.github.com/gists/')) return ok(fx.gist);
    if (configThrows) throw new TypeError('file: fetch failed');
    return config === undefined ? { status: 404, body: '' } : { status: 200, body: config };
  }, clk);
  const location = { search, hash };
  const a = app.createApp({ location, fetch: f, now: clk.now, hidden: clk.hidden });
  return { app, a, f, clk, fx, location };
}

// ---- W03-AC-1: the gist ID
test('W03-AC-1 the gist ID comes from ?gist=, else from config.json; empty or absent gives none', async () => {
  const { resolveGist } = await import('../app.js');
  assert.equal(resolveGist({ search: '?gist=qry111', config: { gist: 'cfg999' } }), 'qry111');
  assert.equal(resolveGist({ search: '?x=1&gist=qry111', config: null }), 'qry111');
  assert.equal(resolveGist({ search: '', config: { gist: 'cfg999' } }), 'cfg999');
  assert.equal(resolveGist({ search: '?gist=', config: { gist: 'cfg999' } }), 'cfg999');
  assert.equal(resolveGist({ search: '', config: null }), null);
  assert.equal(resolveGist({ search: '', config: {} }), null);
  assert.equal(resolveGist({ search: '?other=1', config: { gist: '' } }), null);
});

test('W03-AC-1 the page requests the gist named by ?gist= even when config.json names another', async () => {
  const { a, f } = await page({ search: '?gist=qry111', config: { gist: 'cfg999' } });
  await a.start();
  assert.ok(f.api().length >= 1);
  assert.ok(f.api().every((c) => c.url === 'https://api.github.com/gists/qry111'), 'only the ?gist= gist is requested');
});

test('W03-AC-1 without ?gist= the page reads config.json from its own host and requests that gist', async () => {
  const { a, f } = await page({ config: { gist: 'cfg999' } });
  await a.start();
  const cfg = f.calls.filter((c) => !c.url.startsWith('https://api.github.com/'));
  assert.ok(cfg.length >= 1 && cfg.every((c) => /^(\.\/)?config\.json$/.test(c.url)), 'config.json is fetched by its relative URL');
  assert.deepEqual(f.api().map((c) => c.url), ['https://api.github.com/gists/cfg999']);
});

test('W03-AC-1 with neither ?gist= nor config.json the page shows how to set one and makes no request to api.github.com', async () => {
  for (const variant of [{ config: undefined }, { configThrows: true }, { config: {} }]) {
    const { a, f } = await page(variant);
    await a.start();
    assert.equal(f.api().length, 0, 'no request to api.github.com');
    assert.equal(f.calls.filter((c) => c.url.includes('api.github.com')).length, 0);
    const html = a.render();
    assert.ok(html.includes('?gist='), 'names ?gist=');
    assert.ok(html.includes('config.json'), 'names config.json');
    assert.doesNotMatch(html, /<script/i);
  }
});

// ---- W03-AC-1: the routes
test('W03-AC-1 parseRoute names every route: #/, #/throttle, #/activity, #/repo/<owner>/<name> and an unknown one', async () => {
  const { parseRoute } = await import('../app.js');
  for (const h of ['', '#', '#/']) assert.equal(parseRoute(h).name, 'repos', h);
  assert.equal(parseRoute('#/throttle').name, 'throttle');
  assert.equal(parseRoute('#/activity').name, 'activity');
  assert.deepEqual(parseRoute('#/activity?repo=acme/bravo'), { name: 'activity', repo: 'acme/bravo' });
  assert.deepEqual(parseRoute('#/repo/acme/alpha'), { name: 'repo', repo: 'acme/alpha' });
  for (const h of ['#/nope', '#/repo', '#/repo/acme', '#/throttle/x/y']) assert.equal(parseRoute(h).name, 'not-found', h);
});

test('W03-AC-1 every route renders through the page: #/, #/throttle, #/activity, #/repo/acme/alpha and an unknown one', async () => {
  const { a, location } = await page({ search: '?gist=g1' });
  await a.start();
  const want = { '': 'repos', '#/': 'repos', '#/throttle': 'throttle', '#/activity': 'activity',
    '#/activity?repo=acme/bravo': 'activity', '#/repo/acme/alpha': 'repo', '#/repo/acme/bravo': 'repo', '#/no/such/route': 'not-found' };
  for (const [hash, view] of Object.entries(want)) {
    location.hash = hash;
    const html = a.render();
    assert.equal(typeof html, 'string');
    assert.ok(html.includes(`data-view="${view}"`), `${hash || '(empty)'} renders data-view="${view}"`);
  }
  location.hash = '#/repo/acme/alpha';
  assert.ok(text(a.render()).includes('merged-thing'), 'the repository route shows the repository from the data');
  location.hash = '#/repo/acme/unknown';
  assert.ok(a.render().length > 0, 'a repository not in the data still renders');
  location.hash = '#/activity?repo=acme/bravo';
  const t = text(a.render());
  assert.ok(t.includes('bravo newest event') && !t.includes('node started'), 'the activity route filters by ?repo=');
});

test('W03-AC-1 a text from the data holding <script> or " is escaped on every route of the page', async () => {
  const { a, location, fx } = await page({ search: '?gist=g1' });
  await a.start();
  for (const hash of ['#/', '#/throttle', '#/activity', '#/repo/acme/alpha', '#/repo/acme/bravo', '#/nope']) {
    location.hash = hash;
    const html = a.render();
    assert.ok(!html.includes(fx.hostile.script), `${hash}: no raw ${fx.hostile.script}`);
    assert.doesNotMatch(html, /<script/i, `${hash}: no <script tag`);
  }
  location.hash = '#/repo/acme/alpha';
  assert.ok(a.render().includes('&lt;script&gt;alert(1)&lt;/script&gt;'), 'the planted text is shown, escaped');
});

test('W03-AC-1 a hash holding <script> or " is escaped when an unknown route is shown', async () => {
  const { a, location } = await page({ search: '?gist=g1' });
  await a.start();
  location.hash = '#/<script>alert(1)</script>"';
  const html = a.render();
  assert.doesNotMatch(html, /<script/i);
  assert.ok(!html.includes('"</'), 'no raw quote leaks out of the text');
});

// ---- W03-AC-4: the age and the stale mark, through the page and a fake clock
test('W03-AC-4 the page shows updated and seen as ages that move with the clock without any request', async () => {
  const { a, f, clk, fx } = await page({ search: '?gist=g1' });
  await a.start();
  const before = f.calls.length;
  const base = fx.manifest.seen * 1000;
  clk.advance(2 * MIN); // now = seen + 3 min
  assert.ok(text(a.render()).includes('seen 3 minutes ago'), 'seen 3 minutes ago');
  assert.ok(text(a.render()).includes('updated 3 minutes ago'), 'updated 3 minutes ago');
  clk.advance(4 * MIN); // seen + 7 min
  assert.ok(text(a.render()).includes('seen 7 minutes ago'));
  assert.equal(f.calls.length, before, 'rendering makes no request');
  assert.equal(clk.now(), base + 7 * MIN);
});

test('W03-AC-4 the page is marked stale when the last successful request is over 5 minutes old, and not before', async () => {
  const { a, clk, fx } = await page({ search: '?gist=g1' });
  await a.start(); // a 200 at seen + 1 min
  clk.advance(5 * MIN);
  assert.ok(a.render().includes('data-stale="false"'), 'exactly 5 minutes: not stale');
  clk.advance(1000);
  assert.ok(a.render().includes('data-stale="true"'), 'over 5 minutes: stale');
  assert.ok(fx.manifest.seen * 1000 + 20 * MIN > clk.now(), 'seen itself is still fresh at this point');
});
