// W04-AC-3 (and the view half of W04-AC-1): the explorer's view, site/explorer/view.js, rendered to strings. Each test
// imports the module itself, so a missing module fails each case on its own line. The element reader is dom.mjs.
// The other explorer test files (explorer-ghosts, explorer-url, explorer-page) use the same API, documented here once.
//
// Expected from the implementation (pure: strings out, no DOM, no clock):
//   site/explorer/view.js
//     export renderExplorer(repoFile, view = {}) -> string
//       repoFile  one repo file of the gist ({repo: '<owner>/<name>', nodes: [...], spec_prs: [...], ...}), as
//                 data.files['repo.<owner>.<name>.json']; node entries as scheduler/site.py writes them.
//       view      {node: id|null, tracks: string[]|null, states: string[]|null}: the selected node, the tracks and the
//                 states that are SHOWN; null (or a missing key) = no selection / no filter.
//       The result is one root element <section data-explorer="<owner>/<name>"> holding, in this order: the legend, ONE
//       <svg>, and, only while a node of the graph is selected, the details panel. Every text from the data is escaped.
//       When layout(nodes) (explorer/layout.js) gives an error, the root holds <p data-error="true"> with the layout's
//       message (naming the nodes) and NO <svg>, no legend, no panel, no element with data-node.
//     export parseViewState(hash) -> view      see explorer-url.test.mjs
//     export buildHash(repo, view) -> string   see explorer-url.test.mjs
//
//   The SVG (the nodes' positions come from layout(): data-x / data-y are the node's x and y of the layout of the
//   repository's nodes, filters do not move anything):
//     a real node (an entry of nodes[]): <g data-node="<ID>" data-state="<state>" data-x data-y data-selected="true|false">
//         with, inside it: <rect fill="<colour of the state>" stroke-width="<n>"> and text holding the ID and the name,
//         and <a data-select="<ID>" href="<buildHash(repo, {...view, node: ID})>"> around the label (a click selects).
//         A real node has data-state; a ghost-added node (explorer-ghosts.test.mjs) has none.
//       - ready next (state ready or held): the g holds an element with data-mark="ready-next"; other nodes none.
//       - longest remaining chain (graph.js longestChain): the g and the edges between consecutive chain nodes carry
//         data-chain="true" (other elements no data-chain) and a heavier stroke-width (rect / edge) than the others.
//       - while a node is selected, EVERY g and edge carries data-highlight="true" (the node, its upstream, its
//         downstream, and the edges both of whose ends are among them) or "false" (dimmed); with no selection no element
//         carries data-highlight at all.
//     an edge, one per (dep, node) pair of visible nodes: <path data-edge="<dep>><node>" stroke-width="<n>">.
//     a filter hides the excluded nodes: no g for them and no edge touching them.
//   The legend (outside the <svg>): one <* data-legend="<state>" data-color="<same colour as the nodes' fill>"> per
//     state present in nodes[], its text naming the state.
//   The details panel: <aside data-panel="<ID>"> of the selected node, holding elements with data-field=
//     summary   its text is the summary          size    its text includes the size (when the node has one)
//     track     its text is the track            starts  its text is the number of starts used
//     state     its text names the state and its details: the failure's / question's first line, `waiting for <deps>`,
//               the mergeable status
//     criteria  one <li> per criterion, its text holding the criterion's id and text
//     deps, unlocks  one <a> per ID, its text the ID, href = buildHash(repo, {...view, node: <that ID>}) (selects it)
//     pr        <a href="https://github.com/<repo>/pull/<n>"> when the node has a PR
//     question  the text of a question's first line (state question)
//     issue     <a href="https://github.com/<repo>/issues/<n>"> where the question is answered (from node.url)
//     spec      <a href="https://github.com/<repo>/blob/main/nodes/<ID>-<name>.md">
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadFixture } from './helper.mjs';
import { parse, all, by } from './dom.mjs';

const mod = async () => import('../explorer/view.js');
const alpha = () => loadFixture().files['repo.acme.alpha.json'];
const REPO = 'acme/alpha';
const NL = '#/repo/acme/alpha';
const nodeG = (root, id) => by(root, 'data-node', id)[0];
const realNodes = (root) => by(root, 'data-node').filter((g) => 'data-state' in g.attrs);
const realEdges = (root) => by(root, 'data-edge').filter((e) => !('data-ghost' in e.attrs));
const render = async (repo, view) => parse((await mod()).renderExplorer(repo, view));
const mk = (id, track, deps = [], state = 'waiting', x = {}) => ({
  id, name: `${id.toLowerCase()}-name`, track, deps, unlocks: [], summary: `summary of ${id}`, size: null, has_spec: false,
  criteria: [], starts: 0, state, pr: null, started: null, text: null, url: null, mergeable: null, waiting_for: [], ...x,
});
const repoOf = (nodes, spec_prs = []) => ({ repo: REPO, name: 'alpha', running: false, stop: false, nodes, open_prs: [], spec_prs });

// ---- W04-AC-3: colours and legend
test('W04-AC-3 each node is a labelled box with its ID and name, coloured by its state', async () => {
  const r = alpha();
  const root = await render(r, {});
  assert.equal(all(root, (e) => e.tag === 'svg').length, 1, 'one svg');
  const gs = realNodes(root);
  assert.deepEqual(gs.map((g) => g.attrs['data-node']).sort(), r.nodes.map((n) => n.id).sort());
  for (const n of r.nodes) {
    const g = nodeG(root, n.id);
    assert.equal(g.attrs['data-state'], n.state, n.id);
    assert.ok(g.text.includes(n.id) && g.text.includes(n.name), `${n.id} is labelled with its ID and name`);
    const rect = all(g, (e) => e.tag === 'rect')[0];
    assert.ok(rect && rect.attrs.fill, `${n.id} has a filled box`);
  }
});

test('W04-AC-3 one colour per state: the same state the same colour, two states never the same', async () => {
  const r = alpha();
  const root = await render(r, {});
  const colour = new Map();
  for (const n of r.nodes) {
    const fill = all(nodeG(root, n.id), (e) => e.tag === 'rect')[0].attrs.fill;
    if (colour.has(n.state)) assert.equal(fill, colour.get(n.state), `every ${n.state} node has one colour`);
    colour.set(n.state, fill);
  }
  assert.ok(colour.size >= 5, 'the fixture has several states');
  assert.equal(new Set(colour.values()).size, colour.size, 'distinct colours for distinct states');
});

test('W04-AC-3 the legend names exactly the states present, in the colours of the nodes', async () => {
  const r = alpha();
  const root = await render(r, {});
  const present = [...new Set(r.nodes.map((n) => n.state))].sort();
  const legend = by(root, 'data-legend');
  assert.deepEqual(legend.map((l) => l.attrs['data-legend']).sort(), present);
  for (const l of legend) {
    const st = l.attrs['data-legend'];
    assert.ok(l.text.includes(st), `the legend names ${st} in text`);
    const fill = all(nodeG(root, r.nodes.find((n) => n.state === st).id), (e) => e.tag === 'rect')[0].attrs.fill;
    assert.equal(l.attrs['data-color'], fill, `the legend colour of ${st} is the nodes' fill`);
  }
  assert.ok(!legend.some((l) => l.attrs['data-legend'] === 'ready' || l.attrs['data-legend'] === 'running'), 'no state that is absent');
});

// ---- W04-AC-3: positions
test('W04-AC-3 each node sits at the position the layout gives it', async () => {
  const { layout } = await import('../explorer/layout.js');
  const nodes = [mk('A', 'now', [], 'merged'), mk('B', 'now', ['A'], 'ready'), mk('C', 'later', ['A'], 'waiting', { waiting_for: ['A'] }), mk('D', 'now', ['B', 'C'])];
  const root = await render(repoOf(nodes), {});
  const L = layout(nodes);
  for (const n of nodes) {
    const g = nodeG(root, n.id);
    assert.equal(Number(g.attrs['data-x']), L.positions[n.id].x, `${n.id} x`);
    assert.equal(Number(g.attrs['data-y']), L.positions[n.id].y, `${n.id} y`);
  }
  assert.deepEqual(realEdges(root).map((e) => e.attrs['data-edge']).sort(), ['A>B', 'A>C', 'B>D', 'C>D']);
});

// ---- W04-AC-3: ready next and the longest remaining chain
test('W04-AC-3 the ready-next nodes carry a mark, and only they do', async () => {
  const { readyNext } = await import('../explorer/graph.js');
  const r = alpha();
  const root = await render(r, {});
  const want = readyNext(r.nodes);
  assert.deepEqual(want, ['M02', 'R01', 'Q02'], 'the fixture: the held nodes');
  for (const n of r.nodes) {
    const marks = by(nodeG(root, n.id), 'data-mark', 'ready-next');
    assert.equal(marks.length, want.includes(n.id) ? 1 : 0, `${n.id} ${want.includes(n.id) ? 'has' : 'has no'} the mark`);
  }
});

test('W04-AC-3 the longest remaining chain has a heavier stroke, on its nodes and on the edges between them', async () => {
  const r = alpha();
  const root = await render(r, {});
  const chain = ['M02', 'Y01', 'Z01'];
  const w = (el) => Number(el.attrs['stroke-width']);
  const rectOf = (id) => all(nodeG(root, id), (e) => e.tag === 'rect')[0];
  for (const n of r.nodes) assert.equal(nodeG(root, n.id).attrs['data-chain'] === 'true', chain.includes(n.id), `${n.id} chain flag`);
  const light = r.nodes.filter((n) => !chain.includes(n.id)).map((n) => w(rectOf(n.id)));
  for (const id of chain) assert.ok(w(rectOf(id)) > Math.max(...light), `${id} is drawn heavier`);
  const edges = realEdges(root);
  const inChain = edges.filter((e) => e.attrs['data-chain'] === 'true').map((e) => e.attrs['data-edge']).sort();
  assert.deepEqual(inChain, ['M02>Y01', 'Y01>Z01']);
  const lightE = edges.filter((e) => e.attrs['data-chain'] !== 'true').map(w);
  for (const e of edges.filter((x) => x.attrs['data-chain'] === 'true')) assert.ok(w(e) > Math.max(...lightE), `${e.attrs['data-edge']} is drawn heavier`);
});

test('W04-AC-3 the chain skips merged nodes and follows graph order on a tie', async () => {
  // A merged; B,C wait on A; D waits on B and C: open chains B-D and C-D tie, B comes first
  const nodes = [mk('A', 'now', [], 'merged'), mk('B', 'now', ['A']), mk('C', 'now', ['A']), mk('D', 'now', ['B', 'C'])];
  const root = await render(repoOf(nodes), {});
  const flagged = realNodes(root).filter((g) => g.attrs['data-chain'] === 'true').map((g) => g.attrs['data-node']).sort();
  assert.deepEqual(flagged, ['B', 'D']);
});

// ---- W04-AC-3: highlight
test('W04-AC-3 with no selection nothing is dimmed and no node is selected', async () => {
  const root = await render(alpha(), {});
  assert.equal(by(root, 'data-highlight').length, 0, 'no data-highlight at all');
  assert.ok(realNodes(root).every((g) => g.attrs['data-selected'] === 'false'));
  assert.equal(by(root, 'data-panel').length, 0, 'no details panel');
});

test('W04-AC-3 selecting a node highlights exactly it, its upstream, its downstream and their edges', async () => {
  const r = alpha();
  const cases = { Y01: ['M01', 'M02', 'Y01', 'Z01'], R01: ['M01', 'R01'], M01: ['F01', 'A01', 'M01', 'P01', 'Q01', 'Q02', 'R01', 'S01', 'Y01', 'Z01'], N99: null };
  for (const [sel, set] of Object.entries(cases)) {
    const root = await render(r, { node: sel });
    if (set === null) { // not in the graph: no selection
      assert.equal(by(root, 'data-highlight').length, 0, 'an unknown node selects nothing');
      assert.ok(realNodes(root).every((g) => g.attrs['data-selected'] === 'false'));
      continue;
    }
    for (const n of r.nodes) {
      const g = nodeG(root, n.id);
      assert.equal(g.attrs['data-highlight'], String(set.includes(n.id)), `${sel}: ${n.id} highlight`);
      assert.equal(g.attrs['data-selected'], String(n.id === sel), `${sel}: ${n.id} selected`);
    }
    for (const e of realEdges(root)) {
      const [a, b] = e.attrs['data-edge'].split('>');
      assert.equal(e.attrs['data-highlight'], String(set.includes(a) && set.includes(b)), `${sel}: edge ${e.attrs['data-edge']}`);
    }
  }
});

test('W04-AC-3 every node has a link that selects it, keeping the filters', async () => {
  const { buildHash } = await mod();
  const r = alpha();
  const view = { node: 'Y01', tracks: ['now'], states: null };
  const root = await render(r, view);
  for (const n of r.nodes.filter((x) => x.track === 'now')) {
    const g = nodeG(root, n.id);
    const links = by(g, 'data-select', n.id);
    assert.equal(links.length, 1, `${n.id} has one select link`);
    assert.equal(links[0].attrs.href, buildHash(REPO, { ...view, node: n.id }), n.id);
  }
});

// ---- W04-AC-3: the details panel
const panel = async (id, repo = alpha()) => {
  const root = await render(repo, { node: id });
  const p = by(root, 'data-panel', id);
  assert.equal(p.length, 1, `the panel of ${id}`);
  assert.equal(by(root, 'data-panel').length, 1, 'only one panel');
  return { p: p[0], root };
};
const field = (p, name) => by(p, 'data-field', name)[0];
const links = (el) => all(el, (e) => e.tag === 'a');

test('W04-AC-3 the details panel shows the summary, size, track, state, starts and criteria of the selected node', async () => {
  const r = alpha();
  const y = r.nodes.find((n) => n.id === 'Y01');
  const { p } = await panel('Y01');
  assert.equal(field(p, 'summary').text, y.summary);
  assert.ok(field(p, 'size').text.includes('L'));
  assert.equal(field(p, 'track').text, 'now');
  assert.ok(field(p, 'state').text.includes('waiting'), 'the state');
  assert.ok(field(p, 'state').text.includes('M02'), 'its details: what it waits for');
  assert.equal(field(p, 'starts').text, String(y.starts));
  const crit = all(field(p, 'criteria'), (e) => e.tag === 'li');
  assert.equal(crit.length, y.criteria.length);
  assert.equal(crit.length, 3);
  for (const c of y.criteria) assert.ok(crit.some((li) => li.text.includes(c.id) && li.text.includes(c.text)), `${c.id} is listed with its text`);
  const f = await panel('F01');
  assert.equal(field(f.p, 'starts').text, '2');
});

test('W04-AC-3 the deps and unlocks in the panel are links that select those nodes', async () => {
  const { buildHash } = await mod();
  const view = { node: 'Y01', tracks: ['now', 'later'], states: null };
  const root = await render(alpha(), view);
  const p = by(root, 'data-panel', 'Y01')[0];
  const d = links(field(p, 'deps'));
  assert.deepEqual(d.map((a) => a.text), ['M01', 'M02']);
  for (const a of d) assert.equal(a.attrs.href, buildHash(REPO, { ...view, node: a.text }));
  const u = links(field(p, 'unlocks'));
  assert.deepEqual(u.map((a) => a.text), ['Z01']);
  assert.equal(u[0].attrs.href, buildHash(REPO, { ...view, node: 'Z01' }));
  assert.equal(links(field(by(await render(alpha(), { node: 'M01' }), 'data-panel', 'M01')[0], 'deps')).length, 0, 'M01 has no deps');
});

test('W04-AC-3 the panel links the spec, the PR, the question and the issue', async () => {
  const a = await panel('R01');
  const spec = links(field(a.p, 'spec'));
  assert.equal(spec.length, 1);
  assert.equal(spec[0].attrs.href, 'https://github.com/acme/alpha/blob/main/nodes/R01-running-thing.md');
  assert.equal(by(a.p, 'data-field', 'pr').flatMap(links).length, 0, 'R01 has no PR link');
  const pr = await panel('P01');
  assert.deepEqual(links(field(pr.p, 'pr')).map((x) => x.attrs.href), ['https://github.com/acme/alpha/pull/52']);
  assert.ok(field(pr.p, 'state').text.includes('CONFLICTING'), 'the mergeable status');
  const wp = await panel('S01');
  assert.deepEqual(links(field(wp.p, 'pr')).map((x) => x.attrs.href), ['https://github.com/acme/alpha/pull/51']);
  const q = await panel('Q01');
  assert.deepEqual(links(field(q.p, 'issue')).map((x) => x.attrs.href), ['https://github.com/acme/alpha/issues/12']);
  assert.ok(field(q.p, 'question').text.includes('<script>alert(1)</script>'), 'the question is shown (escaped in the HTML)');
  assert.ok(field(q.p, 'state').text.includes('question'));
  const f = await panel('F01');
  assert.ok(field(f.p, 'state').text.includes('gave up: <script>alert(1)</script>'), 'the failure line is in the state details');
});

test('W04-AC-3 a node that is not in the graph gives no panel', async () => {
  const root = await render(alpha(), { node: 'NOPE' });
  assert.equal(by(root, 'data-panel').length, 0);
});

// ---- W04-AC-3: hostile text
test('W04-AC-3 hostile text from the data appears only escaped, in the graph and in every panel', async () => {
  const { renderExplorer } = await mod();
  const fx = loadFixture();
  const r = fx.files['repo.acme.alpha.json'];
  for (const sel of [null, ...r.nodes.map((n) => n.id)]) {
    const html = renderExplorer(r, { node: sel });
    assert.ok(!html.includes(fx.hostile.script), `${sel}: no raw ${fx.hostile.script}`);
    assert.doesNotMatch(html, /<script/i, `${sel}: no <script tag`);
  }
  const html = renderExplorer(r, { node: 'F01' });
  assert.ok(html.includes('&lt;script&gt;alert(1)&lt;/script&gt;'), 'the planted text is shown, escaped');
  const h = [mk('H1', 'now<script>', [], 'ready', { name: '<script>alert(1)</script>', summary: '"><img src=x>' }), mk('H2', 'now<script>', ['H1'])];
  for (const sel of [null, 'H1', 'H2']) {
    const out = renderExplorer(repoOf(h), { node: sel });
    assert.doesNotMatch(out, /<script/i, `hand-made ${sel}: no <script`);
    assert.doesNotMatch(out, /<img/i, `hand-made ${sel}: no <img`);
  }
});

// ---- W04-AC-1 (view half): a graph that cannot be laid out
test('W04-AC-1 a graph with a cycle renders a message naming the nodes and no SVG', async () => {
  const { renderExplorer } = await mod();
  const nodes = [mk('A', 'now', ['C']), mk('B', 'now', ['A']), mk('C', 'now', ['B']), mk('D', 'now')];
  const html = renderExplorer(repoOf(nodes), {});
  assert.doesNotMatch(html, /<svg/i);
  const root = parse(html);
  const msg = by(root, 'data-error')[0];
  assert.ok(msg, 'a message element');
  for (const id of ['A', 'B', 'C']) assert.ok(msg.text.includes(id), `the message names ${id}`);
  assert.equal(by(root, 'data-node').length, 0, 'nothing is drawn');
});

test('W04-AC-1 a graph with a dep naming no node renders a message naming the node and the missing ID, and no SVG', async () => {
  const { renderExplorer } = await mod();
  const nodes = [mk('A', 'now'), mk('B', 'now', ['A', 'GHOST9'])];
  const html = renderExplorer(repoOf(nodes), { node: 'A' });
  assert.doesNotMatch(html, /<svg/i);
  const msg = by(parse(html), 'data-error')[0];
  assert.ok(msg && msg.text.includes('B') && msg.text.includes('GHOST9'), 'names the node and the missing dep');
  assert.equal(by(parse(html), 'data-panel').length, 0, 'no panel either');
});

test('W04-AC-1 the message of a bad graph is escaped', async () => {
  const { renderExplorer } = await mod();
  const html = renderExplorer(repoOf([mk('<script>alert(1)</script>', 'now', ['X"'])]), {});
  assert.doesNotMatch(html, /<script/i);
  assert.doesNotMatch(html, /<svg/i);
});
