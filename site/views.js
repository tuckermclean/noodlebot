// The status site's views (W03): pure functions from the gist's data to an HTML string. No DOM, no clock of its own.
// Every text from the data goes through escapeHtml; links are built from the repository name and numbers, never
// taken from the data as they are.
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

const NAV = '<nav><a href="#/">Repositories</a> <a href="#/throttle">Throttle</a> <a href="#/activity">Activity</a></nav>';

function page(view, data, ctx, body) {
  const m = data.manifest;
  const stale = isStale({ seen: m.seen, lastSuccess: ctx.lastSuccess, now: ctx.now });
  return `<div data-view="${view}" data-stale="${stale}">\n${NAV}` +
    `<p class="ages">updated ${e(ageText(m.updated, ctx.now))}, seen ${e(ageText(m.seen, ctx.now))}</p>${body}</div>`;
}

const repoFiles = (data) => Object.entries(data.files || {}).filter(([k]) => k.startsWith('repo.')).map(([, v]) => v);
const ghUrl = (repo, kind, n) => `https://github.com/${repo}/${kind}/${n}`;
const link = (href, text) => `<a href="${e(href)}">${e(text)}</a>`;
const prLink = (repo, n) => link(ghUrl(repo, 'pull', n), `#${n}`);
const issueLink = (repo, n) => link(ghUrl(repo, 'issues', n), `#${n}`);

export function renderRepos(data, ctx) {
  const items = repoFiles(data).map((r) => {
    const nodes = r.nodes || [];
    const merged = nodes.filter((n) => n.state === 'merged').length;
    return `<li><a href="#/repo/${e(r.repo)}">${e(r.repo)}</a> ${merged}/${nodes.length} merged` +
      `${r.running ? ', running' : ''}${r.stop ? ', stop requested' : ''}</li>`;
  });
  return page('repos', data, ctx, `<h1>Repositories</h1><ul>${items.join('')}</ul>`);
}

function history(h) {
  if (!h || !h.length) return '<p>No history.</p>';
  const W = 600, H = 150, P = 30;
  const t0 = h[0].t, span = h[h.length - 1].t - t0 || 1;
  const pts = h.map((p) => `${(P + ((p.t - t0) / span) * (W - 2 * P)).toFixed(1)},${(H - P - Math.min(Math.max(p.u, 0), 1) * (H - 2 * P)).toFixed(1)}`);
  return `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="utilization history">` +
    `<polyline fill="none" stroke="currentColor" points="${pts.join(' ')}"/>` +
    `<text x="${P}" y="${H - 8}">${hm(t0)}</text><text x="${W - P}" y="${H - 8}" text-anchor="end">${hm(h[h.length - 1].t)}</text></svg>`;
}

export function renderThrottle(data, ctx) {
  const t = data.files['throttle.json'] || { windows: [], held: false, reason: null, history: [] };
  const wins = (t.windows || []).map((w) =>
    `<tr><td>${e(w.name)}</td><td>${w.utilization == null ? 'n/a' : `${Math.round(w.utilization * 100)}%`}</td>` +
    `<td>${w.resets_at == null ? 'n/a' : utc(w.resets_at)}</td><td>${e(w.status ?? '')}</td></tr>`).join('');
  const state = t.held ? `<p class="held">held: ${e(t.reason ?? '')}</p>` : '<p class="open">open</p>';
  const body = `<h1>Throttle</h1><div data-held="${t.held ? 'true' : 'false'}">${state}</div>` +
    `<table><tr><th>window</th><th>utilization</th><th>resets</th><th>status</th></tr>${wins}</table>${history(t.history)}`;
  return page('throttle', data, ctx, body);
}

export function renderActivity(data, ctx) {
  const act = data.files['activity.json'] || { events: [], triage: [], deploy: { events: [], rejected: [] } };
  const events = (act.events || []).filter((v) => !ctx.repo || v.repo === ctx.repo)
    .map((v) => `<li>${e(v.time)} ${e(v.repo)} ${e(v.text)}</li>`).join('');
  const prs = repoFiles(data).flatMap((r) => (r.open_prs || []).map((p) =>
    `<li>${e(r.repo)} ${prLink(r.repo, p.number)} ${e(p.branch)} ${e(p.mergeable)}</li>`)).join('');
  const triage = (act.triage || []).map((i) =>
    `<li>${e(i.repo)} ${issueLink(i.repo, i.number)} ${e(i.state)} ${e(i.text ?? '')}` +
    `${i.spec_pr ? ` ${prLink(i.repo, i.spec_pr)}` : ''}</li>`).join('');
  const d = act.deploy || { events: [], rejected: [] };
  const deploys = `<p>version ${e(d.version ?? 'none')}, previous ${e(d.previous ?? 'none')}</p>` +
    `<p>rejected: ${(d.rejected || []).map(e).join(', ') || 'none'}</p>` +
    `<ul>${(d.events || []).map((v) => `<li>${e(v.time)} ${e(v.repo)} ${e(v.text)}</li>`).join('')}</ul>`;
  const body = `<h1>Activity${ctx.repo ? ` of ${e(ctx.repo)}` : ''}</h1>` +
    `<section data-section="events"><h2>Events</h2><ul>${events}</ul></section>` +
    `<section data-section="prs"><h2>Open PRs</h2><ul>${prs}</ul></section>` +
    `<section data-section="triage"><h2>Triage</h2><ul>${triage}</ul></section>` +
    `<section data-section="deploys"><h2>Deploys</h2>${deploys}</section>`;
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
  const rows = nodes.map((n) => {
    const det = [];
    if (n.text) det.push(e(n.text));
    if (n.pr) det.push(`PR ${prLink(r.repo, n.pr)}`);
    if (issueNo(n)) det.push(`issue ${issueLink(r.repo, issueNo(n))}`);
    if (n.mergeable) det.push(e(n.mergeable));
    if ((n.waiting_for || []).length) det.push(`waiting for ${n.waiting_for.map(e).join(', ')}`);
    return `<tr data-node="${e(n.id)}"><td>${link(`https://github.com/${r.repo}/blob/main/nodes/${n.id}-${n.name}.md`, n.id)}</td>` +
      `<td>${e(n.name)}</td><td>${e(n.track)}</td><td>${e(n.state)}${det.length ? ` (${det.join('; ')})` : ''}</td>` +
      `<td>${(n.deps || []).map(e).join(', ')}</td><td>${e(n.starts)}</td></tr>`;
  }).join('');
  const head = Object.keys(COLUMNS).map((c) => `<th data-sort="${c}">${c}</th>`).join('');
  const prs = (r.open_prs || []).map((p) => `<li>${prLink(r.repo, p.number)} ${e(p.branch)} ${e(p.mergeable)}</li>`).join('');
  const body = `${title}<section data-section="prs"><h2>Open PRs</h2><ul>${prs}</ul></section>` +
    `<table data-table="nodes"><tr>${head}</tr>${rows}</table>`;
  return page('repo', data, ctx, body);
}
