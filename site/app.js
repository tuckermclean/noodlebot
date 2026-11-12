// The status site's page (W03): the gist ID, the routes, the poller and the views. Nothing here names a repository.
// Importable without a DOM: `document` is touched only in mount().
import { createPoller } from './poll.js';
import { parseViewState, buildHash } from './explorer/view.js';
import { escapeHtml, renderRepos, renderThrottle, renderActivity, renderRepo, page, shell } from './views.js';

export function resolveGist({ search, config }) {
  const q = new URLSearchParams(search || '').get('gist');
  const ok = (v) => typeof v === 'string' && /^[0-9A-Za-z]+$/.test(v);
  if (q) return ok(q) ? q : null;
  return config && ok(config.gist) ? config.gist : null;
}

export function parseRoute(hash) {
  const h = String(hash || '');
  const [path, query = ''] = h.replace(/^#/, '').split('?');
  if (path === '' || path === '/') return { name: 'repos' };
  if (path === '/throttle') return { name: 'throttle' };
  if (path === '/activity') {
    const repo = new URLSearchParams(query).get('repo');
    return repo ? { name: 'activity', repo } : { name: 'activity' };
  }
  const m = /^\/repo\/([^/]+)\/([^/]+)$/.exec(path);
  if (m) return { name: 'repo', repo: `${m[1]}/${m[2]}` };
  return { name: 'not-found' };
}

const HELP = shell('setup', {}, '<h1>No status gist set</h1>' +
  '<p>Open this page with <code>?gist=&lt;gist id&gt;</code>, or set the gist ID in <code>config.json</code> ' +
  '(<code>{"gist": "&lt;gist id&gt;"}</code>).</p>');

export function createApp({ location, fetch, now, hidden }) {
  const app = { gist: null, poller: null, cur: null, prev: null, changedAt: null };

  async function readConfig() {
    try {
      const r = await fetch('config.json', { credentials: 'omit' });
      if (r.status !== 200) return null;
      return await r.json();
    } catch {
      return null;
    }
  }

  // the previous data and when the current data replaced it: recorded whenever the poller's data object changes
  // (a 304 keeps the object), not when a route is drawn
  const track = () => {
    const d = app.poller && app.poller.state.data;
    if (!d || d === app.cur) return;
    app.prev = app.cur;
    app.cur = d;
    app.changedAt = now();
  };

  app.start = async () => {
    let config = null;
    if (!resolveGist({ search: location.search, config: null })) config = await readConfig();
    app.gist = resolveGist({ search: location.search, config });
    if (!app.gist) return;
    app.poller = createPoller({ gist: app.gist, fetch, now, hidden });
    await app.poller.tick();
    track();
  };

  app.tick = async () => {
    if (!app.poller) return false;
    const r = await app.poller.tick();
    track();
    return r;
  };

  app.render = () => {
    if (!app.gist || !app.poller) return HELP;
    const route = parseRoute(location.hash);
    const st = app.poller.state;
    track();
    const notice = app.poller.statusText();
    if (!st.data) {
      const msg = st.message ? ` (${escapeHtml(st.message)})` : '';
      const view = route.name === 'not-found' ? 'not-found' : route.name;
      return shell(view, { stale: true, notice }, `<p>${st.status === 'schema' ? '' : `No data yet${msg}.`}</p>`);
    }
    const ctx = { now: now(), lastSuccess: st.lastSuccess, prev: app.prev, changedAt: app.changedAt, repo: route.repo, view: parseViewState(location.hash), notice, ...(app.sort || {}) };
    if (route.name === 'not-found') {
      return page('not-found', st.data, ctx, `<p>No such page: ${escapeHtml(location.hash)}</p>`);
    }
    const view = { repos: renderRepos, throttle: renderThrottle, activity: renderActivity, repo: renderRepo }[route.name];
    return view(st.data, ctx);
  };

  app.setSort = (sort, dir) => { app.sort = { sort, dir }; };
  return app;
}

// The browser: wires the DOM. Not run in Node (no `document`).
export function mount(doc = document, win = window) {
  const root = doc.getElementById('app');
  const app = createApp({
    location: win.location, fetch: (u, i) => win.fetch(u, i), now: () => Date.now(), hidden: () => doc.hidden,
  });
  let last = null;
  const draw = () => {
    const html = app.render();
    if (html === last) return;
    last = html;
    const old = root.querySelector && root.querySelector('.explorer-scroll');
    const left = old ? old.scrollLeft : 0, top = old ? old.scrollTop : 0;
    root.innerHTML = html;
    const cur = old && root.querySelector('.explorer-scroll');
    if (cur) { cur.scrollLeft = left; cur.scrollTop = top; }
  };
  root.addEventListener('click', (ev) => {
    const th = ev.target.closest && ev.target.closest('th[data-sort]');
    if (!th) return;
    const col = th.getAttribute('data-sort');
    const same = app.sort && app.sort.sort === col;
    app.setSort(col, same && app.sort.dir === 'asc' ? 'desc' : 'asc');
    draw();
  });
  // clearing the selection: the same view without node=
  const clearSelection = () => {
    const route = parseRoute(win.location.hash);
    if (route.name !== 'repo') return;
    const view = parseViewState(win.location.hash);
    if (view.node) win.location.hash = buildHash(route.repo, { ...view, node: null });
  };
  root.addEventListener('click', (ev) => {
    const t = ev.target;
    if (!t || !t.closest || !t.closest('.explorer-scroll') || t.closest('a')) return;
    clearSelection();
  });
  doc.addEventListener('keydown', (ev) => { if (ev.key === 'Escape') clearSelection(); });
  win.addEventListener('hashchange', draw);
  doc.addEventListener('visibilitychange', async () => { await app.tick(); draw(); });
  draw();
  app.start().then(draw);
  win.setInterval(async () => { await app.tick(); draw(); }, 1000);
  return app;
}

if (typeof document !== 'undefined') mount();
