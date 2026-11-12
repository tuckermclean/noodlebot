// The status site's views (W03): pure functions from the gist's data to an HTML string. No DOM, no clock of its own.
// Every text from the data goes through escapeHtml; links are built from the repository name and numbers, never
// taken from the data as they are.
import { renderExplorer, buildHash, stateVar } from './explorer/view.js';
const MIN = 60 * 1000;
const STALE_SEEN = 20 * MIN; // the manifest's `seen` older than this: stale
const STALE_SUCCESS = 5 * MIN; // the last successful request older than this: stale

export function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}
const e = escapeHtml;

export function ageText(seconds, nowMs) {
  const n = Math.max(0, Math.floor((nowMs - seconds * 1000) / MIN));
  return `${n} minutes ago`;
}

export function isStale({ seen, lastSuccess, now }) {
  if (lastSuccess === null || lastSuccess === undefined) return true;
  return now - seen * 1000 > STALE_SEEN || now - lastSuccess > STALE_SUCCESS;
}

const utc = (s) => {
  const i = new Date(s * 1000).toISOString();
  return `${i.slice(0, 10)} ${i.slice(11, 16)} UTC`;
};
const hm = (s) => new Date(s * 1000).toISOString().slice(11, 16);

const NAV_LINKS = [['#/', 'Repositories', 'repos'], ['#/throttle', 'Throttle', 'throttle'], ['#/activity', 'Activity', 'activity']];
// the navigation link of the current route (a repository's page counts as the repositories link; an unknown route has none)
const currentLink = (view) => (view === 'repo' ? 'repos' : view);
const nav = (view) => `<nav aria-label="Pages">${NAV_LINKS.map(([href, text, id]) =>
  `<a href="${href}"${id === currentLink(view) ? ' aria-current="page"' : ''}>${text}</a>`).join('')}</nav>`;

// The one shell every view sits in: a header (name, navigation, the data's age), a banner for a notice, the body.
// `pill` is the age pill's HTML or ''. `notice` is a text (escaped here) or ''.
export function shell(view, { stale = false, pill = '', notice = '' } = {}, body = '') {
  const banner = notice ? `<p class="notice" role="status">${e(notice)}</p>` : '';
  return `<div data-view="${e(view)}" data-stale="${stale}" class="shell">\n` +
    `<header class="site-header"><span class="brand">noodlebot status</span>${nav(view)}${pill}</header>` +
    `${banner}<div class="view-body">${body}</div></div>`;
}

export function agePill(m, ctx, stale) {
  const ages = `updated ${e(ageText(m.updated, ctx.now))}, seen ${e(ageText(m.seen, ctx.now))}`;
  return stale
    ? `<p class="ages pill" data-live="stale"><span class="dot" aria-hidden="true"></span><strong>stale</strong> ${ages}</p>`
    : `<p class="ages pill" data-live="fresh"><span class="dot" aria-hidden="true"></span>${ages}</p>`;
}

export function page(view, data, ctx, body) {
  const m = data.manifest;
  const stale = isStale({ seen: m.seen, lastSuccess: ctx.lastSuccess, now: ctx.now });
  return shell(view, { stale, pill: agePill(m, ctx, stale), notice: ctx.notice || '' }, body);
}

// a badge: its colour is a state's one --state-<state> (any other state: --state-other), or a rule of style.css for it
const badge = (value, text = value) => `<span class="badge" data-badge="${e(value)}">${e(text)}</span>`;
const stateBadge = (state) => `<span class="badge" data-badge="${e(state)}" style="background:${stateVar(state)}">${e(state)}</span>`;
const table = (inner, attrs = '') => `<div class="table-scroll"><table${attrs}>${inner}</table></div>`;

// The change mark (W06): what differs from the data before, for 2 minutes after the new data arrived (by the page's
// clock). ctx.prev is the previous data (null for the first), ctx.changedAt the time the current data replaced it.
const MARK_MS = 2 * MIN;
const prevData = (ctx) => (ctx.prev && ctx.changedAt != null && ctx.now - ctx.changedAt < MARK_MS ? ctx.prev : null);
const NEW = ' data-new="true"';
const prevRepo = (ctx, repo) => { const p = prevData(ctx); return p ? repoFiles(p).find((f) => f.repo === repo) || null : null; };
const countsOf = (r) => { const c = {}; for (const n of r.nodes || []) c[n.state] = (c[n.state] || 0) + 1; return JSON.stringify(c); };
const evKey = (v) => JSON.stringify([v.time, v.repo, v.text]);
// the ids of the nodes of `r` whose state differs from the previous data's (or that are not in it)
export function changedNodes(r, ctx) {
  const before = prevRepo(ctx, r.repo);
  if (!before) return new Set();
  const old = new Map((before.nodes || []).map((n) => [n.id, n.state]));
  return new Set((r.nodes || []).filter((n) => old.get(n.id) !== n.state).map((n) => n.id));
}

const repoFiles = (data) => Object.entries(data.files || {}).filter(([k]) => k.startsWith('repo.')).map(([, v]) => v);
const ghUrl = (repo, kind, n) => `https://github.com/${repo}/${kind}/${n}`;
const link = (href, text) => `<a href="${e(href)}">${e(text)}</a>`;
const prLink = (repo, n) => link(ghUrl(repo, 'pull', n), `#${n}`);
const issueLink = (repo, n) => link(ghUrl(repo, 'issues', n), `#${n}`);

const loopBadges = (r) => badge(r.running ? 'running' : 'idle') + (r.stop ? ` ${badge('STOP', 'STOP requested')}` : '');

export function renderRepos(data, ctx) {
  const items = repoFiles(data).map((r) => {
    const before = prevRepo(ctx, r.repo);
    const isNew = before && (!!before.running !== !!r.running || !!before.stop !== !!r.stop || countsOf(before) !== countsOf(r));
    const nodes = r.nodes || [];
    const counts = {};
    for (const n of nodes) counts[n.state] = (counts[n.state] || 0) + 1;
    const merged = counts.merged || 0;
    const segs = Object.entries(counts).map(([k, v]) =>
      `<span class="seg" data-state="${e(k)}" title="${v} ${e(k)}" style="width:${((100 * v) / nodes.length).toFixed(1)}%;background:${stateVar(k)}"></span>`).join('');
    const summary = nodes.length ? `<p class="count">${merged} of ${nodes.length} merged</p><div class="bar" role="img" aria-label="node states">${segs}</div>`
      : '<p class="count">no nodes</p>';
    return `<li class="card" data-card="${e(r.repo)}"${isNew ? NEW : ''}><div class="card-head"><h2><a href="#/repo/${e(r.repo)}">${e(r.repo)}</a></h2>` +
      `<span class="loop">${loopBadges(r)}</span></div>${summary}</li>`;
  });
  return page('repos', data, ctx, `<h1>Repositories</h1><ul class="cards">${items.join('')}</ul>`);
}

function history(h) {
  if (!h || !h.length) return '<p>No history.</p>';
  const W = 600, H = 170, PL = 44, PR = 16, PT = 12, PB = 30;
  const t0 = h[0].t, span = h[h.length - 1].t - t0 || 1;
  const x = (t) => PL + ((t - t0) / span) * (W - PL - PR);
  const y = (u) => H - PB - Math.min(Math.max(u, 0), 1) * (H - PT - PB);
  const pts = h.map((p) => `${x(p.t).toFixed(1)},${y(p.u).toFixed(1)}`);
  const base = y(0).toFixed(1);
  const area = `${x(h[0].t).toFixed(1)},${base} ${pts.join(' ')} ${x(h[h.length - 1].t).toFixed(1)},${base}`;
  const grid = [[1, '100%'], [0.5, '50%'], [0, '0%']].map(([u, l]) =>
    `<line class="grid" x1="${PL}" y1="${y(u).toFixed(1)}" x2="${W - PR}" y2="${y(u).toFixed(1)}"/>` +
    `<text class="axis" x="${PL - 6}" y="${(y(u) + 4).toFixed(1)}" text-anchor="end">${l}</text>`).join('');
  return `<svg class="chart" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="utilization history">` +
    `${grid}<polygon class="area" points="${area}"/><polyline class="line" fill="none" points="${pts.join(' ')}"/>` +
    `<text class="axis" x="${PL}" y="${H - 8}">${hm(t0)}</text><text class="axis" x="${W - PR}" y="${H - 8}" text-anchor="end">${hm(h[h.length - 1].t)}</text></svg>`;
}

// `resets in <h> h <m> min`, or `<m> min` under an hour: from the page's clock, so it moves without a request
function countdown(resetsAt, nowMs) {
  const mins = Math.max(0, Math.floor((resetsAt * 1000 - nowMs) / MIN));
  const h = Math.floor(mins / 60);
  return `resets in ${h ? `${h} h ${mins % 60} min` : `${mins} min`}`;
}

export function renderThrottle(data, ctx) {
  const t = data.files['throttle.json'] || { windows: [], held: false, reason: null, history: [] };
  const wins = (t.windows || []).map((w) => {
    const has = w.utilization != null;
    const pct = has ? `${Math.round(w.utilization * 100)}%` : 'n/a';
    const gauge = has ? `<meter value="${e(w.utilization)}" min="0" max="1" high="0.8" optimum="0">${pct}</meter>` : '';
    const reset = w.resets_at == null ? '<p class="reset">resets n/a</p>'
      : `<p class="reset">${utc(w.resets_at)} <span class="countdown">${countdown(w.resets_at, ctx.now)}</span></p>`;
    return `<li class="window" data-window="${e(w.name)}"><div class="window-head"><h2>${e(w.name)}</h2><span class="pct">${pct}</span></div>` +
      `${gauge}${reset}<p class="status">${e(w.status ?? '')}</p></li>`;
  }).join('');
  const state = t.held ? `<p class="held">${badge('held')} <span class="reason">${e(t.reason ?? '')}</span></p>` : `<p class="open">${badge('open')}</p>`;
  const body = `<h1>Throttle</h1><div class="panel" data-held="${t.held ? 'true' : 'false'}">${state}</div>` +
    `<ul class="windows">${wins}</ul><div class="panel chart-panel">${history(t.history)}</div>`;
  return page('throttle', data, ctx, body);
}

const eventItem = (v, isNew = false) => `<li${isNew ? NEW : ''}><time>${e(v.time)}</time> <span class="ev-repo">${e(v.repo)}</span> <span class="ev-text">${e(v.text)}</span></li>`;

// the events grouped by the date of their `time`, newest day first, W03's order within a day
function timeline(events, seen) {
  const days = new Map();
  for (const v of events) {
    const d = String(v.time ?? '').slice(0, 10);
    days.set(d, [...(days.get(d) || []), v]);
  }
  return [...days.entries()].sort((a, b) => (a[0] < b[0] ? 1 : a[0] > b[0] ? -1 : 0))
    .map(([d, evs]) => `<div class="day"><h3>${e(d)}</h3><ul class="timeline">${evs.map((v) => eventItem(v, !!seen && !seen.has(evKey(v)))).join('')}</ul></div>`).join('');
}

const mergeBadge = (m) => badge(m);

export function renderActivity(data, ctx) {
  const act = data.files['activity.json'] || { events: [], triage: [], deploy: { events: [], rejected: [] } };
  const pd = prevData(ctx);
  const seen = pd ? new Set((((pd.files || {})['activity.json'] || {}).events || []).map(evKey)) : null;
  const events = timeline((act.events || []).filter((v) => !ctx.repo || v.repo === ctx.repo), seen);
  const prs = repoFiles(data).flatMap((r) => (r.open_prs || []).map((p) =>
    `<li>${e(r.repo)} ${prLink(r.repo, p.number)} ${e(p.branch)} ${mergeBadge(p.mergeable)}</li>`)).join('');
  const triage = (act.triage || []).map((i) =>
    `<li>${e(i.repo)} ${issueLink(i.repo, i.number)} ${stateBadge(i.state)} ${e(i.text ?? '')}` +
    `${i.spec_pr ? ` ${prLink(i.repo, i.spec_pr)}` : ''}</li>`).join('');
  const d = act.deploy || { events: [], rejected: [] };
  const deploys = `<p>version ${e(d.version ?? 'none')}, previous ${e(d.previous ?? 'none')}</p>` +
    `<p>rejected: ${(d.rejected || []).map(e).join(', ') || 'none'}</p>` +
    `<ul>${(d.events || []).map((v) => eventItem(v)).join('')}</ul>`;
  const cur = (on) => (on ? ' aria-current="true"' : '');
  const filters = `<p class="filter">filter: <a href="#/activity"${cur(!ctx.repo)}>all</a>` +
    `${repoFiles(data).map((r) => ` <a href="#/activity?repo=${e(r.repo)}"${cur(ctx.repo === r.repo)}>${e(r.repo)}</a>`).join('')}</p>`;
  const body = `<h1>Activity${ctx.repo ? ` of ${e(ctx.repo)}` : ''}</h1>${filters}` +
    `<section class="panel" data-section="events"><h2>Events</h2>${events}</section>` +
    `<section class="panel" data-section="prs"><h2>Open PRs</h2><ul>${prs}</ul></section>` +
    `<section class="panel" data-section="triage"><h2>Triage</h2><ul>${triage}</ul></section>` +
    `<section class="panel" data-section="deploys"><h2>Deploys</h2>${deploys}</section>`;
  return page('activity', data, ctx, body);
}

const COLUMNS = {
  id: (n) => n.id, name: (n) => n.name, track: (n) => n.track, state: (n) => n.state,
  deps: (n) => (n.deps || []).join(','), starts: (n) => n.starts,
};

export function renderRepo(data, ctx) {
  const r = repoFiles(data).find((f) => f.repo === ctx.repo);
  const title = `<h1>${e(ctx.repo)}</h1>`;
  if (!r) return page('repo', data, ctx, `${title}<p>This repository is not in the data.</p>`);
  let nodes = [...(r.nodes || [])];
  const key = COLUMNS[ctx.sort];
  if (key) {
    const sign = ctx.dir === 'desc' ? -1 : 1;
    nodes.sort((a, b) => {
      const x = key(a), y = key(b);
      return sign * (x < y ? -1 : x > y ? 1 : 0);
    });
  }
  const issueNo = (n) => { const m = /\/issues\/(\d+)$/.exec(n.url || ''); return m ? m[1] : null; };
  const view = ctx.view || {};
  const changed = changedNodes(r, ctx);
  const rows = nodes.map((n) => {
    const det = [];
    if (n.text) det.push(e(n.text));
    if (n.pr) det.push(`PR ${prLink(r.repo, n.pr)}`);
    if (issueNo(n)) det.push(`issue ${issueLink(r.repo, issueNo(n))}`);
    if (n.mergeable) det.push(e(n.mergeable));
    if ((n.waiting_for || []).length) det.push(`waiting for ${n.waiting_for.map(e).join(', ')}`);
    return `<tr data-node="${e(n.id)}" data-selected="${n.id === view.node}"${changed.has(n.id) ? NEW : ''}><td>${link(`https://github.com/${r.repo}/blob/main/nodes/${n.id}-${n.name}.md`, n.id)}</td>` +
      `<td><a data-select="${e(n.id)}" href="${e(buildHash(r.repo, { ...view, node: n.id }))}">${e(n.name)}</a></td><td>${e(n.track)}</td><td>${stateBadge(n.state)}${det.length ? ` (${det.join('; ')})` : ''}</td>` +
      `<td>${(n.deps || []).map(e).join(', ')}</td><td>${e(n.starts)}</td></tr>`;
  }).join('');
  const head = Object.keys(COLUMNS).map((c) => `<th data-sort="${c}">${c}</th>`).join('');
  const prs = (r.open_prs || []).map((p) => `<li>${prLink(r.repo, p.number)} ${e(p.branch)} ${mergeBadge(p.mergeable)}</li>`).join('');
  const loop = `<p class="loop" data-loop="${r.running ? 'running' : 'idle'}">loop: ${badge(r.running ? 'running' : 'idle')}</p>` +
    `<p class="stop" data-stop="${r.stop ? 'true' : 'false'}">STOP: ${r.stop ? badge('STOP', 'requested') : 'not set'}</p>`;
  const body = `${title}<div class="loop-state">${loop}</div><section class="panel" data-section="prs"><h2>Open PRs</h2><ul>${prs}</ul></section>` +
    `${renderExplorer(r, view, changed)}` +
    table(`<tr>${head}</tr>${rows}`, ' data-table="nodes"');
  return page('repo', data, ctx, body);
}
