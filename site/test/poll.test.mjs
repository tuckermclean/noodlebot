// W03-AC-2 and W03-AC-3: the poller (site/poll.js), with a fake fetch, a fake clock and a fake visibility.
// The module interface is documented at the top of helper.mjs (createPoller, SCHEMA_MAJOR, poller.tick(),
// poller.state, poller.statusText()). Each test imports the module itself, so a missing module fails each case
// on its own line.
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadFixture, clock, fakeFetch, gistBody, T0 } from './helper.mjs';

const GIST = 'abc123def456';
const URL_ = `https://api.github.com/gists/${GIST}`;
const MIN = 60000;

async function make(handler, opts = {}) {
  const { createPoller } = await import('../poll.js');
  const clk = clock();
  const fx = loadFixture();
  const f = fakeFetch((c, n) => handler(c, n, fx), clk);
  const p = createPoller({ gist: GIST, fetch: f, now: clk.now, hidden: clk.hidden, ...opts });
  return { p, clk, f, fx };
}
const ok = (body, etag = '"e1"') => ({ status: 200, headers: { ETag: etag, 'Content-Type': 'application/json' }, body });

// ---- W03-AC-2
test('W03-AC-2 the first request is a GET of the gist without credentials, with the GitHub Accept header and no If-None-Match', async () => {
  const { p, f } = await make((c, n, fx) => ok(fx.gist));
  assert.equal(await p.tick(), true);
  const c = f.calls[0];
  assert.equal(c.url, URL_);
  assert.match(c.headers.get('accept') || '', /application\/vnd\.github\+json/);
  assert.equal(c.headers.get('authorization'), null);
  assert.notEqual(c.init.credentials, 'include');
  assert.equal(c.headers.get('if-none-match'), null);
  assert.equal(p.state.status, 'ok');
  assert.equal(p.state.etag, '"e1"');
});

test('W03-AC-2 the next request sends If-None-Match with the last ETag; a 304 keeps the data, a 200 replaces it', async () => {
  const bump = (fx, k) => gistBody(fx, { mutate: (g) => { const m = JSON.parse(g.files['manifest.json'].content); m.updated += k; g.files['manifest.json'].content = JSON.stringify(m); } });
  const { p, clk, f } = await make((c, n, fx) => {
    if (n === 1) return ok(bump(fx, 0), '"e1"');
    if (n === 2) return { status: 304, headers: { ETag: '"e1"' } };
    return ok(bump(fx, 5), '"e2"');
  });
  await p.tick();
  const first = p.state.data;
  assert.ok(first && first.manifest, 'data after the first 200');
  const upd1 = first.manifest.updated;
  clk.advance(MIN);
  assert.equal(await p.tick(), true);
  assert.equal(f.calls[1].headers.get('if-none-match'), '"e1"');
  assert.deepEqual(p.state.data, first, 'a 304 keeps the data');
  assert.equal(p.state.lastSuccess, clk.now(), 'a 304 is a successful request');
  assert.equal(p.state.status, 'ok');
  clk.advance(MIN);
  await p.tick();
  assert.equal(f.calls[2].headers.get('if-none-match'), '"e1"');
  assert.equal(p.state.data.manifest.updated, upd1 + 5, 'a 200 replaces the data');
  assert.equal(p.state.etag, '"e2"');
  clk.advance(MIN);
  await p.tick();
  assert.equal(f.calls[3].headers.get('if-none-match'), '"e2"');
});

test('W03-AC-2 a 200 parses every file into state.data.files and the manifest into state.data.manifest', async () => {
  const { p, fx } = await make((c, n, fx) => ok(fx.gist));
  await p.tick();
  assert.deepEqual(p.state.data.manifest, fx.manifest);
  assert.deepEqual(p.state.data.files, fx.files);
});

test('W03-AC-2 a file marked truncated is read from its raw_url, not from its content', async () => {
  const rawUrl = 'https://gist.githubusercontent.com/raw/xyz/throttle.json';
  let name, full;
  const { p, f } = await make((c, n, fx) => {
    if (c.url === rawUrl) return { status: 200, body: full };
    name = Object.keys(fx.gist.files).find((k) => k !== 'manifest.json');
    full = fx.gist.files[name].content;
    return ok(gistBody(fx, { mutate: (g) => { g.files[name].content = full.slice(0, 5); g.files[name].truncated = true; g.files[name].raw_url = rawUrl; } }));
  });
  await p.tick();
  assert.ok(f.calls.some((c) => c.url === rawUrl), 'the raw_url was requested');
  assert.deepEqual(p.state.data.files[name], JSON.parse(full));
});

test('W03-AC-2 it polls every 60 seconds while visible: nothing at 59 s, a request at 60 s', async () => {
  const { p, clk, f } = await make((c, n, fx) => ok(fx.gist));
  await p.tick();
  clk.advance(59000);
  assert.equal(await p.tick(), false);
  assert.equal(f.api().length, 1);
  clk.advance(1000);
  assert.equal(await p.tick(), true);
  assert.equal(f.api().length, 2);
});

test('W03-AC-2 it makes no request while the tab is hidden, however long', async () => {
  const { p, clk, f } = await make((c, n, fx) => ok(fx.gist));
  clk.hiddenNow = true;
  for (let i = 0; i < 40; i++) { assert.equal(await p.tick(), false); clk.advance(30000); }
  assert.equal(f.calls.length, 0);
});

test('W03-AC-2 on becoming visible after 60 seconds it polls at once', async () => {
  const { p, clk, f } = await make((c, n, fx) => ok(fx.gist));
  await p.tick();
  clk.hiddenNow = true;
  clk.advance(5 * MIN);
  assert.equal(await p.tick(), false);
  assert.equal(f.api().length, 1);
  clk.hiddenNow = false;
  assert.equal(await p.tick(), true, 'the first tick after becoming visible polls');
  assert.equal(f.api().length, 2);
});

test('W03-AC-2 on becoming visible less than 60 seconds after the last request it does not poll yet', async () => {
  const { p, clk, f } = await make((c, n, fx) => ok(fx.gist));
  await p.tick();
  clk.hiddenNow = true;
  clk.advance(20000);
  await p.tick();
  clk.hiddenNow = false;
  assert.equal(await p.tick(), false);
  clk.advance(40000);
  assert.equal(await p.tick(), true);
  assert.equal(f.api().length, 2);
});

// the most requests in any window of 60 minutes (half-open: [t, t + 60 min))
function worst(times) {
  let w = 0;
  for (let i = 0; i < times.length; i++) {
    let j = i;
    while (j < times.length && times[j] - times[i] < 60 * MIN) j++;
    w = Math.max(w, j - i);
  }
  return w;
}
async function play(steps) {
  const { p, clk, f } = await make((c, n, fx) => (n === 1 ? ok(fx.gist) : { status: 304, headers: { ETag: '"e1"' } }));
  await steps(p, clk);
  return f.api().map((c) => c.time);
}
const HOURS3 = 3 * 60 * MIN;

test('W03-AC-2 at most 55 requests in any 60 minutes while visible all the time (ticks every 7 s for 3 hours)', async () => {
  const times = await play(async (p, clk) => { for (let t = 0; t < HOURS3; t += 7000) { await p.tick(); clk.advance(7000); } });
  assert.ok(times.length >= 100, `it keeps polling (${times.length} requests in 3 hours)`);
  assert.ok(worst(times) <= 55, `${worst(times)} requests in some 60 minutes`);
});

test('W03-AC-2 at most 55 requests in any 60 minutes when the tab flips hidden and visible every 30 seconds for 3 hours', async () => {
  const times = await play(async (p, clk) => {
    for (let t = 0; t < HOURS3; t += 5000) {
      if (t % 30000 === 0) clk.hiddenNow = !clk.hiddenNow;
      await p.tick();
      clk.advance(5000);
    }
  });
  assert.ok(times.length > 0);
  assert.ok(worst(times) <= 55, `${worst(times)} requests in some 60 minutes`);
});

test('W03-AC-2 at most 55 requests in any 60 minutes under random visibility changes and pauses (seeded, 3 hours)', async () => {
  for (const seed of [1, 7, 42]) {
    let s = seed;
    const rnd = () => (s = (s * 1103515245 + 12345) % 2147483648) / 2147483648;
    const times = await play(async (p, clk) => {
      const end = clk.now() + HOURS3;
      while (clk.now() < end) {
        if (rnd() < 0.5) clk.hiddenNow = !clk.hiddenNow;
        await p.tick();
        clk.advance(1000 + Math.floor(rnd() * 89000));
      }
    });
    assert.ok(worst(times) <= 55, `seed ${seed}: ${worst(times)} requests in some 60 minutes`);
  }
});

test('W03-AC-2 data whose manifest names a different schema major version is not shown', async () => {
  const { p, clk, fx } = await make((c, n, fx) => ok(gistBody(fx, { version: 2 })));
  await p.tick();
  assert.equal(p.state.data, null);
  assert.equal(p.state.status, 'schema');
  void clk; void fx;
});

test('W03-AC-2 a different schema major version replaces data already held, and the page says it needs a newer front end', async () => {
  const { p, clk } = await make((c, n, fx) => (n === 1 ? ok(fx.gist, '"e1"') : ok(gistBody(fx, { version: 2 }), '"e2"')));
  await p.tick();
  assert.ok(p.state.data);
  clk.advance(MIN);
  await p.tick();
  assert.equal(p.state.data, null);
  assert.match(p.statusText(), /newer front end/i);
});

test('W03-AC-2 the page schema major version is exported as SCHEMA_MAJOR = 1', async () => {
  const m = await import('../poll.js');
  assert.equal(m.SCHEMA_MAJOR, 1);
});

// ---- W03-AC-3
const limited = (status, headers) => ({ status, headers, body: { message: 'rate limited' } });

// after answer `r` at the start, when does the next request go out? (resolution one second)
async function nextAt(r, extra = {}) {
  const { p, clk, f } = await make((c, n, fx) => (n === 1 ? r : ok(fx.gist)), extra);
  await p.tick();
  const t0 = clk.now();
  let waited = 0;
  while (waited < 3 * 60 * MIN) {
    clk.advance(1000); waited += 1000;
    if (await p.tick()) break;
  }
  return { waited, p, clk, f, t0 };
}

test('W03-AC-3 after a 403 with Retry-After the next request waits that many seconds', async () => {
  const { waited } = await nextAt(limited(403, { 'Retry-After': '300' }));
  assert.equal(waited, 300000);
});

test('W03-AC-3 after a 429 with Retry-After the next request waits that many seconds', async () => {
  const { waited } = await nextAt(limited(429, { 'Retry-After': '45' }));
  // never sooner than the retry-after; the 60-second poll interval may apply on top
  assert.ok(waited >= 45000 && waited <= 60000, `waited ${waited} ms`);
});

test('W03-AC-3 Retry-After wins over X-RateLimit-Reset', async () => {
  const reset = Math.floor((T0 + 20 * MIN) / 1000);
  const { waited } = await nextAt(limited(403, { 'Retry-After': '120', 'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': String(reset) }));
  assert.equal(waited, 120000);
});

test('W03-AC-3 without Retry-After and with 0 requests remaining it waits until X-RateLimit-Reset', async () => {
  const reset = Math.floor((T0 + 17 * MIN) / 1000);
  const { waited } = await nextAt(limited(403, { 'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': String(reset) }));
  assert.equal(waited, 17 * MIN);
});

test('W03-AC-3 X-RateLimit-Reset is ignored while requests remain: it waits 2 minutes', async () => {
  const reset = Math.floor((T0 + 17 * MIN) / 1000);
  const { waited } = await nextAt(limited(429, { 'X-RateLimit-Remaining': '3', 'X-RateLimit-Reset': String(reset) }));
  assert.equal(waited, 2 * MIN);
});

test('W03-AC-3 without any header, repeated 403s wait 2, 4, 8, 16 minutes, then 30 and 30', async () => {
  const { p, clk, f } = await make((c, n) => limited(n % 2 ? 403 : 429, {}));
  await p.tick();
  const waits = [];
  for (let k = 0; k < 6; k++) {
    const t = clk.now();
    let n = f.calls.length;
    for (let w = 0; w < 40 * MIN && f.calls.length === n; w += 1000) { clk.advance(1000); await p.tick(); }
    waits.push((clk.now() - t) / MIN);
  }
  assert.deepEqual(waits, [2, 4, 8, 16, 30, 30]);
});

test('W03-AC-3 the page says it is backing off and until when', async () => {
  const { p, clk } = await make((c, n, fx) => limited(403, { 'Retry-After': '600' }));
  await p.tick();
  const until = clk.now() + 600000;
  assert.equal(p.state.status, 'backoff');
  assert.equal(p.state.backoffUntil, until);
  const text = p.statusText();
  assert.match(text, /backing off until /i);
  assert.ok(text.includes(new Date(until).toISOString().slice(11, 16)), `"${text}" holds the UTC time ${new Date(until).toISOString().slice(11, 16)}`);
});

test('W03-AC-3 a success after a backoff restores the 60-second poll, drops the backoff text and resets the doubling', async () => {
  const { p, clk, f } = await make((c, n, fx) => (n === 1 ? limited(403, {}) : n === 2 ? ok(fx.gist) : n === 4 ? limited(429, {}) : ok(fx.gist)));
  await p.tick();
  clk.advance(2 * MIN);
  assert.equal(await p.tick(), true);
  assert.equal(p.state.status, 'ok');
  assert.equal(p.state.backoffUntil, null);
  assert.doesNotMatch(p.statusText(), /backing off/i);
  clk.advance(59000);
  assert.equal(await p.tick(), false);
  clk.advance(1000);
  assert.equal(await p.tick(), true, 'polls 60 s after the success');
  clk.advance(MIN);
  assert.equal(await p.tick(), true, 'the 4th request gets a 429 with no headers');
  // the wait is 2 minutes again, not 4
  clk.advance(2 * MIN - 1000);
  assert.equal(await p.tick(), false);
  clk.advance(1000);
  assert.equal(await p.tick(), true);
  assert.equal(f.api().length, 5);
});

test('W03-AC-3 no request goes out before the backoff is over, visible or not', async () => {
  const { p, clk, f } = await make((c, n, fx) => limited(403, { 'Retry-After': '600' }));
  await p.tick();
  for (let i = 0; i < 9; i++) {
    clk.advance(59000);
    clk.hiddenNow = i % 2 === 1;
    await p.tick();
    clk.hiddenNow = false;
    await p.tick();
  }
  assert.ok(clk.now() < T0 + 600000);
  assert.equal(f.api().length, 1);
});
