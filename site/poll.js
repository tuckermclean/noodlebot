// The status site's poller (W03): requests the gist, keeps the data, and obeys the rate rules.
// No timers and no Date.now: the page calls tick() every second and on `visibilitychange`, with an injected clock.
export const SCHEMA_MAJOR = 1;

const INTERVAL = 60 * 1000; // between two requests while visible
const BACKOFF_FIRST = 2 * 60 * 1000;
const BACKOFF_MAX = 30 * 60 * 1000;
const HOUR = 60 * 60 * 1000;
const HOURLY_CAP = 55; // requests to api.github.com in any 60 minutes; raw_url fetches go to gist.githubusercontent.com, outside that limit, so they are not counted

function major(v) {
  const n = parseInt(String(v), 10);
  return Number.isNaN(n) ? null : n;
}

export function createPoller({ gist, fetch, now, hidden }) {
  const state = {
    status: 'idle', data: null, etag: null, lastRequest: null, lastSuccess: null, backoffUntil: null, message: '',
  };
  const times = []; // the times of the requests of the last hour
  let backoffStep = 0;
  let busy = false;

  function due(t) {
    if (hidden()) return false;
    while (times.length && t - times[0] >= HOUR) times.shift();
    if (times.length >= HOURLY_CAP) return false;
    if (state.backoffUntil !== null) return t >= state.backoffUntil;
    return state.lastRequest === null || t - state.lastRequest >= INTERVAL;
  }

  function backoff(t, res) {
    const header = (n) => (res && res.headers ? res.headers.get(n) : null);
    let wait = null;
    const retry = header('retry-after');
    const date = retry && /^\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/.test(retry) ? Date.parse(retry) : NaN; // Retry-After may be an HTTP date
    if (retry !== null && retry !== '' && Number.isFinite(Number(retry)) && Number(retry) >= 0) {
      wait = Number(retry) * 1000;
    } else if (Number.isFinite(date)) {
      wait = Math.max(0, date - t);
    } else if (header('x-ratelimit-remaining') === '0' && Number.isFinite(Number(header('x-ratelimit-reset')))) {
      wait = Math.max(0, Number(header('x-ratelimit-reset')) * 1000 - t);
    }
    if (wait === null) {
      wait = Math.min(BACKOFF_FIRST * 2 ** backoffStep, BACKOFF_MAX);
      backoffStep++;
    }
    state.backoffUntil = t + Math.max(wait, INTERVAL); // never retry sooner than the poll interval
    state.status = 'backoff';
  }

  async function read(body) {
    const files = {};
    for (const [name, f] of Object.entries(body.files || {})) {
      let text = f.content;
      if (f.truncated) {
        const r = await fetch(f.raw_url, { headers: { Accept: 'text/plain' }, credentials: 'omit' });
        if (r.status !== 200) throw new Error(`raw_url answered ${r.status}`);
        text = await r.text();
      }
      files[name] = JSON.parse(text);
    }
    const manifest = files['manifest.json'];
    if (!manifest) throw new Error('no manifest.json');
    delete files['manifest.json'];
    return { manifest, files };
  }

  async function tick() {
    if (busy) return false;
    const t = now();
    if (!due(t)) return false;
    busy = true;
    times.push(t);
    state.lastRequest = t;
    try {
      const headers = { Accept: 'application/vnd.github+json' };
      if (state.etag) headers['If-None-Match'] = state.etag;
      const res = await fetch(`https://api.github.com/gists/${gist}`, { headers, credentials: 'omit' });
      if (res.status === 304) {
        state.lastSuccess = t;
        state.backoffUntil = null;
        backoffStep = 0;
        if (state.status === 'backoff' || state.status === 'idle') state.status = state.data ? 'ok' : 'idle';
      } else if (res.status === 200) {
        const got = await read(await res.json());
        state.etag = res.headers.get('etag');
        state.lastSuccess = t;
        state.backoffUntil = null;
        backoffStep = 0;
        if (major(got.manifest.version) === SCHEMA_MAJOR) {
          state.data = got;
          state.status = 'ok';
          state.message = '';
        } else {
          state.data = null;
          state.status = 'schema';
          state.message = 'newer front end';
        }
      } else {
        backoff(t, res);
        state.message = `the gist answered ${res.status}`;
      }
    } catch (e) {
      backoff(t, null);
      state.message = `request failed: ${e && e.message ? e.message : e}`;
    } finally {
      busy = false;
    }
    return true;
  }

  function statusText() {
    if (state.status === 'backoff') {
      return `backing off until ${new Date(state.backoffUntil).toISOString().slice(11, 16)} UTC (${state.message})`;
    }
    if (state.status === 'schema') return 'This data needs a newer front end than this page.';
    return '';
  }

  return { tick, state, statusText };
}
