// The explorer's view (W04): a repository file's nodes as plain SVG strings, a legend, filter links and a details panel.
// Pure: strings out, no DOM, no clock. Every text from the data goes through escapeHtml; links are built from the
// repository name and numbers, never taken from the data as they are.
import { escapeHtml } from '../views.js';
import { layout } from './layout.js';
import { upstream, downstream, readyNext, longestChain, ghosts } from './graph.js';

const e = escapeHtml;
const BOX_W = 160;
const BOX_H = 44;
const COL_W = 200;
const ROW_H = 64;
const PAD = 16;

const COLOURS = {
  merged: '#9ad29a', running: '#6fb1e8', failed: '#e57373', question: '#f2c14e', answered: '#f7e08a',
  'waiting-pr': '#b39ddb', 'pr-open': '#80cbc4', ready: '#4caf50', held: '#ffb74d', waiting: '#e0e0e0',
};
const OTHER = '#bdbdbd';
const colour = (state) => (Object.hasOwn(COLOURS, state) ? COLOURS[state] : OTHER);

const ghUrl = (repo, kind, n) => `https://github.com/${repo}/${kind}/${n}`;
const num = (n) => Number(n) || 0;

// ---- the URL state: #/repo/<owner>/<name>?node=<ID>&track=<list>&state=<list>
export function buildHash(repo, view = {}) {
  const q = [];
  if (view.node) q.push(`node=${encodeURIComponent(view.node)}`);
  if (view.tracks) q.push(`track=${view.tracks.map(encodeURIComponent).join(',')}`);
  if (view.states) q.push(`state=${view.states.map(encodeURIComponent).join(',')}`);
  return `#/repo/${repo}${q.length ? `?${q.join('&')}` : ''}`;
}

const decode = (s) => { try { return decodeURIComponent(s); } catch { return s; } };

export function parseViewState(hash) {
  const out = { node: null, tracks: null, states: null };
  const h = String(hash || '').replace(/^#/, '');
  const i = h.indexOf('?');
  if (!/^\/repo\//.test(i < 0 ? h : h.slice(0, i)) || i < 0) return out;
  for (const part of h.slice(i + 1).split('&')) {
    const j = part.indexOf('=');
    if (j < 0) continue;
    const k = part.slice(0, j), v = part.slice(j + 1);
    const list = () => (v === '' ? [] : v.split(',').map(decode));
    if (k === 'node') out.node = v === '' ? null : decode(v);
    else if (k === 'track') out.tracks = list();
    else if (k === 'state') out.states = list();
  }
  return out;
}

// ---- the pieces
const issueNo = (n) => { const m = /\/issues\/(\d+)$/.exec(n.url || ''); return m ? m[1] : null; };

function legend(nodes) {
  const present = [...new Set(nodes.map((n) => n.state))].sort();
  const items = present.map((s) => `<span data-legend="${e(s)}" data-color="${colour(s)}">` +
    `<span class="swatch" style="background:${colour(s)}"></span> ${e(s)}</span>`);
  return `<p class="legend">${items.join(' ')} <span class="legend-note">ready next: ringed dot; heavy outline: longest remaining chain; dashed: spec PR</span></p>`;
}

// links that toggle one track or state in the hash (the lists hold what is SHOWN; everything shown = no filter)
function filters(repo, nodes, view) {
  const toggles = (label, all, key, cur) => {
    const links = all.map((v) => {
      const on = cur ? cur.includes(v) : true;
      const next = all.filter((x) => (x === v ? !on : cur ? cur.includes(x) : true));
      const href = buildHash(repo, { ...view, [key]: next.length === all.length ? null : next });
      return `<a data-filter="${e(v)}" data-on="${on}" href="${e(href)}">${on ? '[x]' : '[ ]'} ${e(v)}</a>`;
    });
    return `<span data-filters="${label}">${label}: ${links.join(' ')}</span>`;
  };
  const tracks = [...new Set(nodes.map((n) => n.track))];
  const states = [...new Set(nodes.map((n) => n.state))].sort();
  return `<p class="filters">${toggles('track', tracks, 'tracks', view.tracks)} ${toggles('state', states, 'states', view.states)}</p>`;
}

function panel(repo, r, n, view, tags = []) {
  const sel = (id) => `<a href="${e(buildHash(repo, { ...view, node: id }))}">${e(id)}</a>`;
  const det = [];
  if (n.text) det.push(e(n.text));
  if ((n.waiting_for || []).length) det.push(`waiting for ${n.waiting_for.map(e).join(', ')}`);
  if (n.mergeable) det.push(e(n.mergeable));
  const crit = (n.criteria || []).map((c) => `<li>${e(c.id)} ${e(c.text)}</li>`).join('');
  const issue = issueNo(n);
  const field = (name, html) => `<p>${name}: <span data-field="${name}">${html}</span></p>`;
  return `<aside data-panel="${e(n.id)}"><h2>${e(n.id)} ${e(n.name)}</h2>` +
    field('summary', e(n.summary)) + (n.size ? field('size', e(n.size)) : '') + field('track', e(n.track)) +
    field('state', `${e(n.state)}${det.length ? ` (${det.join('; ')})` : ''}`) + field('starts', e(n.starts)) +
    `<div>criteria: <ul data-field="criteria">${crit}</ul></div>` +
    field('deps', (n.deps || []).map(sel).join(', ')) + field('unlocks', (n.unlocks || []).map(sel).join(', ')) +
    (n.pr ? field('pr', `<a href="${e(ghUrl(repo, 'pull', num(n.pr)))}">#${num(n.pr)}</a>`) : '') +
    ((n.state === 'question' || n.state === 'answered') && n.text ? field('question', e(n.text)) : '') +
    (issue ? field('issue', `<a href="${e(ghUrl(repo, 'issues', issue))}">#${e(issue)}</a>`) : '') +
    field('spec', `<a href="${e(`https://github.com/${repo}/blob/main/nodes/${n.id}-${n.name}.md`)}">${e(`${n.id}-${n.name}.md`)}</a>`) +
    tags.map((t) => `<p data-ghost-note="${e(t.kind)}">PR <a href="${e(ghUrl(repo, 'pull', num(t.pr)))}">#${num(t.pr)}</a> ${t.kind === 'changed' ? `changes it: ${Object.keys(t.fields || {}).map(e).join(', ')}` : e(t.kind)}</p>`).join('') +
    '</aside>';
}

export function renderExplorer(r, view = {}) {
  const repo = r.repo;
  const nodes = r.nodes || [];
  const root = (inner) => `<section data-explorer="${e(repo)}">${inner}</section>`;
  const L = layout(nodes);
  if (L.error) return root(`<p data-error="true">${e(L.error)}</p>`);

  const by = new Map(nodes.map((n) => [n.id, n]));
  const shown = (track, state) => (!view.tracks || view.tracks.includes(track)) && (state === null || !view.states || view.states.includes(state));
  const visible = nodes.filter((n) => shown(n.track, n.state));
  const vis = new Set(visible.map((n) => n.id));

  const sel = view.node && by.has(view.node) ? view.node : null;
  let lit = null;
  if (sel) lit = new Set([sel, ...upstream(nodes, sel), ...downstream(nodes, sel)]);
  const inLit = (id) => (lit ? lit.has(id) : false);
  const hl = (on) => (sel ? ` data-highlight="${on}"` : '');

  const chain = longestChain(nodes);
  const chainSet = new Set(chain);
  const chainEdge = new Set(chain.slice(1).map((id, i) => `${chain[i]}>${id}`));
  const ready = new Set(readyNext(nodes));

  // ghosts
  const gs = ghosts(r.spec_prs || []);
  const tagsOf = new Map(); // id -> ghosts on a real node
  for (const g of gs) if (g.kind !== 'added' && by.has(g.id)) tagsOf.set(g.id, [...(tagsOf.get(g.id) || []), g]);
  const added = gs.filter((g) => g.kind === 'added' && !by.has(g.id) && shown(g.track, null));

  const pos = L.positions;
  const bottom = L.bands.length ? L.bands[L.bands.length - 1].y + L.bands[L.bands.length - 1].height : 0;
  const ghostPos = new Map();
  added.forEach((g, i) => {
    const c = Math.max(0, ...(g.deps || []).filter((d) => pos[d]).map((d) => pos[d].col + 1));
    ghostPos.set(g, { x: c * COL_W, y: bottom + PAD + i * ROW_H });
  });
  const ncol = Math.max(0, ...Object.values(pos).map((p) => p.col + 1), ...[...ghostPos.values()].map((p) => p.x / COL_W + 1));
  const W = Math.max(1, ncol) * COL_W;
  const H = bottom + (added.length ? PAD + added.length * ROW_H : 0);

  const prTag = (repoName, g, i) => {
    const what = g.kind === 'changed' ? `: ${Object.keys(g.fields || {}).map(e).join(', ')}` : '';
    return `<a href="${e(ghUrl(repoName, 'pull', num(g.pr)))}"><text x="6" y="${30 + i * 10}" font-size="10">#${num(g.pr)}${what}</text></a>`;
  };

  const edges = [];
  for (const n of visible) {
    for (const d of n.deps) {
      if (!vis.has(d)) continue;
      const a = pos[d], b = pos[n.id];
      const x1 = a.x + BOX_W, y1 = a.y + BOX_H / 2, x2 = b.x, y2 = b.y + BOX_H / 2, mx = (x1 + x2) / 2;
      const id = `${d}>${n.id}`;
      const heavy = chainEdge.has(id);
      edges.push(`<path data-edge="${e(id)}"${heavy ? ' data-chain="true"' : ''}${hl(inLit(d) && inLit(n.id))} fill="none" stroke="#555" stroke-width="${heavy ? 4 : 1.5}" d="M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}"/>`);
    }
  }
  for (const g of added) {
    const b = ghostPos.get(g);
    for (const d of g.deps || []) {
      if (!vis.has(d)) continue;
      const a = pos[d];
      const x1 = a.x + BOX_W, y1 = a.y + BOX_H / 2, x2 = b.x, y2 = b.y + BOX_H / 2, mx = (x1 + x2) / 2;
      edges.push(`<path data-edge="${e(`${d}>${g.id}`)}" data-ghost="added" data-pr="${num(g.pr)}"${hl(false)} fill="none" stroke="#555" stroke-width="1.5" stroke-dasharray="6 4" d="M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}"/>`);
    }
  }

  const boxes = visible.map((n) => {
    const p = pos[n.id];
    const tags = tagsOf.get(n.id) || [];
    const first = tags[0];
    const attrs = first ? ` data-ghost="${first.kind}" data-pr="${num(first.pr)}"` +
      (first.kind === 'changed' ? ` data-changed="${e(Object.keys(first.fields).join(','))}"` : '') : '';
    const struck = tags.some((t) => t.kind === 'removed');
    const heavy = chainSet.has(n.id);
    const href = buildHash(repo, { ...view, node: n.id });
    const dash = tags.some((t) => t.kind === 'changed') ? ' stroke-dasharray="3 3"' : '';
    const rect = `<rect width="${BOX_W}" height="${BOX_H}" rx="4" fill="${colour(n.state)}" stroke="#000" stroke-width="${heavy ? 4 : 1}"${dash}/>` +
      (n.id === sel ? `<rect data-outline="selected" width="${BOX_W}" height="${BOX_H}" rx="4" fill="none" stroke="#06c" stroke-width="2" pointer-events="none"/>` : '');
    const mark = ready.has(n.id) ? `<circle data-mark="ready-next" cx="${BOX_W - 10}" cy="10" r="5" fill="#fff" stroke="#000" stroke-width="2"/>` : '';
    const label = `<a data-select="${e(n.id)}" href="${e(href)}">${rect}<text x="6" y="18" font-size="12"${struck ? ' text-decoration="line-through"' : ''}>${e(n.id)} ${e(n.name)}</text>${mark}</a>`;
    const tagText = tags.map((t, i) => prTag(repo, t, i)).join('');
    return `<g data-node="${e(n.id)}" data-state="${e(n.state)}" data-x="${p.x}" data-y="${p.y}" data-selected="${n.id === sel}"` +
      `${heavy ? ' data-chain="true"' : ''}${attrs}${hl(inLit(n.id))} transform="translate(${p.x},${p.y})">` +
      `${label}${tagText}</g>`;
  });
  for (const g of added) {
    const p = ghostPos.get(g);
    boxes.push(`<g data-node="${e(g.id)}" data-ghost="added" data-pr="${num(g.pr)}" data-x="${p.x}" data-y="${p.y}"${hl(false)} transform="translate(${p.x},${p.y})">` +
      `<rect width="${BOX_W}" height="${BOX_H}" rx="4" fill="#fff" stroke="#000" stroke-width="1" stroke-dasharray="6 4"/>` +
      `<text x="6" y="18" font-size="12">${e(g.id)} ${e(g.name)}</text>${prTag(repo, g, 0)}</g>`);
  }

  const bands = L.bands.map((b) => `<text x="2" y="${b.y + 10}" font-size="10" fill="#777">${e(b.track)}</text>`).join('');
  const svg = `<div class="explorer-scroll"><svg viewBox="0 0 ${W} ${Math.max(H, 1)}" width="${W}" height="${Math.max(H, 1)}" role="img" aria-label="node graph">${bands}${edges.join('')}${boxes.join('')}</svg></div>`;
  const det = sel ? panel(repo, r, by.get(sel), view, tagsOf.get(sel) || []) : '';
  return root(`${filters(repo, nodes, view)}${legend(nodes)}${svg}${det}`);
}
