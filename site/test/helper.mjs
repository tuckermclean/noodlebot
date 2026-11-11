// Shared helpers of the front end's node:test files (not itself a test: only *.test.mjs files are run).
//
// Expected from the implementation, as the tests use it (documented once here; see each test file too):
//   site/poll.js   export SCHEMA_MAJOR = 1
//                  export createPoller({gist, fetch, now, hidden}) -> poller
//                    gist    gist ID; the request goes to https://api.github.com/gists/<gist>
//                    fetch   fetch(url, init) -> Response-like {status, headers.get(name), json(), text()}
//                    now     () -> milliseconds since the epoch (the clock; the poller never reads Date.now itself)
//                    hidden  () -> true while the tab is hidden (document.hidden)
//                  poller.tick() -> Promise<boolean>: makes a request if and only if one is due now (visible, 60 s
//                    since the last request or the backoff over, under the hourly cap); true when it made one. The
//                    poller starts no timers: the page calls tick() every second and on `visibilitychange`.
//                  poller.state -> {status, data, etag, lastRequest, lastSuccess, backoffUntil, message}
//                    status        'idle' | 'ok' | 'backoff' | 'schema'
//                    data          null, or {manifest, files}: manifest = the parsed manifest.json, files = every
//                                  other gist file by its name, parsed as JSON; null while the schema major differs
//                    etag          the last ETag header seen, or null
//                    lastRequest   ms of the last request made (any answer), or null
//                    lastSuccess   ms of the last 200 or 304, or null
//                    backoffUntil  ms before which no request is made after a 403 or 429, else null
//                  poller.statusText() -> string for the page. While backing off it contains "backing off until "
//                    and that time as UTC "HH:MM" (new Date(backoffUntil).toISOString().slice(11, 16)); with a
//                    different schema major it contains "newer front end"; otherwise it contains neither.
import { readFileSync } from 'node:fs';

// The fixture directory built by site/site.test.sh from scheduler/testdata/site by `site.py build` and
// `site.py publish` (a manifest as W02 writes it): $SITE_FIXTURE holds
//   gist.json        {"files": {"<name>": {"filename", "content", "truncated": false, "raw_url"}}}: the answer of
//                    GET /gists/<id>, manifest.json included
//   files/<name>     each gist file's content, as published
//   hostile.json     {"script": "<script>alert(1)</script>", "quote": "\"", "where": [...]}: the hostile texts
//                    planted in the data (a node's question, a failure, an event, a triage question, a branch)
export function loadFixture() {
  const dir = process.env.SITE_FIXTURE;
  if (!dir) throw new Error('SITE_FIXTURE is not set: run these tests through site/site.test.sh');
  const gist = JSON.parse(readFileSync(`${dir}/gist.json`, 'utf8'));
  const files = {};
  for (const [name, f] of Object.entries(gist.files)) files[name] = JSON.parse(f.content);
  const manifest = files['manifest.json'];
  delete files['manifest.json'];
  return { dir, gist, manifest, files, hostile: JSON.parse(readFileSync(`${dir}/hostile.json`, 'utf8')) };
}

export const T0 = Date.UTC(2026, 10, 10, 12, 0, 0);

export function clock(start = T0) {
  const c = { t: start, now: () => c.t, advance(ms) { c.t += ms; }, hiddenNow: false, hidden: () => c.hiddenNow };
  return c;
}

// gistBody(fixture, {version, truncate}) -> a fresh gist answer (deep copy); `version` rewrites the manifest's.
export function gistBody(fx, { version, mutate } = {}) {
  const g = JSON.parse(JSON.stringify(fx.gist));
  if (version !== undefined) {
    const m = JSON.parse(g.files['manifest.json'].content);
    m.version = version;
    g.files['manifest.json'].content = JSON.stringify(m);
  }
  if (mutate) mutate(g);
  return g;
}

// fakeFetch(handler, clk): records every call as {url, headers (a Headers), init, time}; handler(call, n)
// returns {status, headers, body} (body an object or a string).
export function fakeFetch(handler, clk) {
  const calls = [];
  const f = async (url, init = {}) => {
    const call = { url: String(url), headers: new Headers(init.headers || {}), init, time: clk.now() };
    calls.push(call);
    const r = await handler(call, calls.length);
    const body = r.body === undefined || r.status === 304 ? null : typeof r.body === 'string' ? r.body : JSON.stringify(r.body);
    return new Response(body, { status: r.status ?? 200, headers: r.headers || {} });
  };
  f.calls = calls;
  f.api = () => calls.filter((c) => c.url.startsWith('https://api.github.com/gists/'));
  return f;
}
