// W04-AC-5: the filters and the URL state of the explorer, site/explorer/view.js (API in explorer-view.test.mjs).
// Each test imports the module itself.
//
// Expected from the implementation:
//   site/explorer/view.js
//     export buildHash(repo, view) -> string
//       '#/repo/<owner>/<name>' plus, in this order and only for what is set, '?node=<ID>', 'track=<list>',
//       'state=<list>' joined by '&' ('?' before the first). view = {node, tracks, states} (null = not set). A list is
//       the SHOWN tracks / states: each item encodeURIComponent'ed, joined by ',' in the order given; an empty list
//       (everything hidden) is written 'track=' / 'state='. The node ID is encodeURIComponent'ed.
//         {} -> '#/repo/acme/alpha'; {node: 'R01'} -> '#/repo/acme/alpha?node=R01';
//         {node: 'R01', tracks: ['now'], states: ['ready', 'merged']} -> '#/repo/acme/alpha?node=R01&track=now&state=ready,merged'
//     export parseViewState(hash) -> {node, tracks, states}
//       the inverse: absent parameters give null; items are decoded; a list's order is kept; '' (an empty list) gives [];
//       other parameters and an unknown route are ignored (the result is then all null).
//   Filters (renderExplorer's view.tracks / view.states): a node is shown only when its track is in tracks (when set)
//   and its state is in states (when set); the others get no <g>, and no edge touching them is drawn.
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadFixture } from './helper.mjs';
import { parse, all, by } from './dom.mjs';

const mod = async () => import('../explorer/view.js');
const alpha = () => loadFixture().files['repo.acme.alpha.json'];
const realNodes = (root) => by(root, 'data-node').filter((g) => 'data-state' in g.attrs);
const realEdges = (root) => by(root, 'data-edge').filter((e) => !('data-ghost' in e.attrs));

const filtered = async (view) => {
  const { renderExplorer } = await mod();
  const r = alpha();
  const root = parse(renderExplorer(r, view));
  const shown = new Set(r.nodes.filter((n) => (!view.tracks || view.tracks.includes(n.track)) && (!view.states || view.states.includes(n.state))).map((n) => n.id));
  const edges = r.nodes.flatMap((n) => n.deps.map((d) => `${d}>${n.id}`)).filter((e) => e.split('>').every((id) => shown.has(id)));
  return { root, shown, edges };
};

// ---- filters
test('W04-AC-5 a track filter hides exactly the nodes of the other tracks and every edge touching them', async () => {
  for (const tracks of [['later'], ['now'], ['now', 'later']]) {
    const { root, shown, edges } = await filtered({ tracks });
    assert.deepEqual(realNodes(root).map((g) => g.attrs['data-node']).sort(), [...shown].sort(), `tracks ${tracks}`);
    assert.deepEqual(realEdges(root).map((e) => e.attrs['data-edge']).sort(), edges.sort(), `edges of tracks ${tracks}`);
  }
  const later = await filtered({ tracks: ['later'] });
  assert.deepEqual([...later.shown].sort(), ['Q02', 'Z01']);
  assert.deepEqual(later.edges, [], 'no edge between the two later nodes: their deps are in now');
});

test('W04-AC-5 a state filter hides exactly the nodes in the other states and every edge touching them', async () => {
  for (const states of [['merged'], ['held', 'waiting'], ['failed', 'question', 'answered', 'pr-open', 'waiting-pr']]) {
    const { root, shown, edges } = await filtered({ states });
    assert.deepEqual(realNodes(root).map((g) => g.attrs['data-node']).sort(), [...shown].sort(), `states ${states}`);
    assert.deepEqual(realEdges(root).map((e) => e.attrs['data-edge']).sort(), edges.sort(), `edges of states ${states}`);
  }
  const m = await filtered({ states: ['merged'] });
  assert.deepEqual([...m.shown].sort(), ['M01'], 'only M01 is merged in the fixture');
  assert.deepEqual(m.edges, []);
});

test('W04-AC-5 a track and a state filter together hide the nodes either one excludes', async () => {
  const { root, shown, edges } = await filtered({ tracks: ['now'], states: ['merged', 'held', 'waiting'] });
  assert.deepEqual([...shown].sort(), ['M01', 'M02', 'R01', 'Y01']);
  assert.deepEqual(realNodes(root).map((g) => g.attrs['data-node']).sort(), [...shown].sort());
  assert.deepEqual(realEdges(root).map((e) => e.attrs['data-edge']).sort(), edges.sort());
  assert.deepEqual(edges.sort(), ['M01>R01', 'M01>Y01', 'M02>Y01']);
});

test('W04-AC-5 an empty list hides every node and every edge; no filter hides none', async () => {
  const none = await filtered({ tracks: [] });
  assert.equal(realNodes(none.root).length, 0);
  assert.equal(realEdges(none.root).length, 0);
  const sn = await filtered({ states: [] });
  assert.equal(realNodes(sn.root).length, 0);
  const all_ = await filtered({});
  assert.equal(realNodes(all_.root).length, alpha().nodes.length);
  assert.equal(realEdges(all_.root).length, alpha().nodes.flatMap((n) => n.deps).length);
  const nulls = await filtered({ node: null, tracks: null, states: null });
  assert.equal(realNodes(nulls.root).length, alpha().nodes.length);
});

test('W04-AC-5 a filter does not move the nodes that stay', async () => {
  const full = await filtered({});
  const part = await filtered({ tracks: ['now'], states: ['merged', 'held', 'waiting'] });
  for (const g of realNodes(part.root)) {
    const f = by(full.root, 'data-node', g.attrs['data-node'])[0];
    assert.equal(g.attrs['data-x'], f.attrs['data-x']);
    assert.equal(g.attrs['data-y'], f.attrs['data-y']);
  }
});

// ---- the URL state
const VIEWS = () => [
  { node: null, tracks: null, states: null },
  { node: 'R01', tracks: null, states: null },
  { node: null, tracks: ['later'], states: null },
  { node: null, tracks: null, states: ['merged', 'held'] },
  { node: 'Y01', tracks: ['now', 'later'], states: ['merged', 'held', 'waiting'] },
  { node: 'M02', tracks: [], states: [] },
  { node: 'Z01', tracks: ['now'], states: ['waiting'] },
];

test('W04-AC-5 buildHash writes #/repo/<owner>/<name>?node=<ID>&track=<list>&state=<list> from what is set', async () => {
  const { buildHash } = await mod();
  assert.equal(buildHash('acme/alpha', {}), '#/repo/acme/alpha');
  assert.equal(buildHash('acme/alpha', { node: null, tracks: null, states: null }), '#/repo/acme/alpha');
  assert.equal(buildHash('acme/alpha', { node: 'R01' }), '#/repo/acme/alpha?node=R01');
  assert.equal(buildHash('acme/alpha', { tracks: ['later'] }), '#/repo/acme/alpha?track=later');
  assert.equal(buildHash('acme/alpha', { states: ['ready', 'merged'] }), '#/repo/acme/alpha?state=ready,merged');
  assert.equal(buildHash('acme/alpha', { node: 'R01', tracks: ['now'], states: ['ready', 'merged'] }), '#/repo/acme/alpha?node=R01&track=now&state=ready,merged');
  assert.equal(buildHash('acme/alpha', { tracks: [], states: [] }), '#/repo/acme/alpha?track=&state=');
});

test('W04-AC-5 parseViewState reads them back; absent parameters give null, an empty list gives []', async () => {
  const { parseViewState } = await mod();
  assert.deepEqual(parseViewState('#/repo/acme/alpha'), { node: null, tracks: null, states: null });
  assert.deepEqual(parseViewState('#/repo/acme/alpha?node=R01&track=now&state=ready,merged'), { node: 'R01', tracks: ['now'], states: ['ready', 'merged'] });
  assert.deepEqual(parseViewState('#/repo/acme/alpha?state=held,waiting&node=Y01'), { node: 'Y01', tracks: null, states: ['held', 'waiting'] });
  assert.deepEqual(parseViewState('#/repo/acme/alpha?track=&state='), { node: null, tracks: [], states: [] });
  assert.deepEqual(parseViewState('#/repo/acme/alpha?other=1&node=A01'), { node: 'A01', tracks: null, states: null });
});

test('W04-AC-5 a view state round-trips through the hash, items with commas and spaces included', async () => {
  const { buildHash, parseViewState } = await mod();
  for (const v of [...VIEWS(), { node: 'A b&c', tracks: ['a,b', 'c d', 'e&f=g'], states: ['x%y'] }]) {
    assert.deepEqual(parseViewState(buildHash('acme/alpha', v)), v, JSON.stringify(v));
    assert.deepEqual(parseViewState(buildHash('acme/alpha', parseViewState(buildHash('acme/alpha', v)))), v);
  }
  const h = buildHash('acme/alpha', { node: 'A b&c', tracks: ['a,b'] });
  assert.equal(h.split('?').length, 2, 'one query string');
  assert.equal(h.split('?')[1].split('&').length, 2, 'the special characters are encoded: two parameters');
});

test('W04-AC-5 rendering from the hash gives the same view as rendering from the state it was built from', async () => {
  const { renderExplorer, buildHash, parseViewState } = await mod();
  const r = alpha();
  for (const v of VIEWS()) {
    const viaHash = renderExplorer(r, parseViewState(buildHash(r.repo, v)));
    assert.equal(viaHash, renderExplorer(r, v), JSON.stringify(v));
  }
  const url = '#/repo/acme/alpha?node=Y01&track=now&state=merged,held,waiting';
  assert.equal(buildHash(r.repo, parseViewState(url)), url);
  assert.equal(renderExplorer(r, parseViewState(url)), renderExplorer(r, { node: 'Y01', tracks: ['now'], states: ['merged', 'held', 'waiting'] }));
});

test('W04-AC-5 the rendered view is the one the hash names: the selection and the filters show in the output', async () => {
  const { renderExplorer, parseViewState } = await mod();
  const root = parse(renderExplorer(alpha(), parseViewState('#/repo/acme/alpha?node=Y01&track=now&state=merged,held,waiting')));
  assert.deepEqual(realNodes(root).map((g) => g.attrs['data-node']).sort(), ['M01', 'M02', 'R01', 'Y01']);
  assert.deepEqual(realNodes(root).filter((g) => g.attrs['data-selected'] === 'true').map((g) => g.attrs['data-node']), ['Y01']);
  assert.equal(by(root, 'data-panel', 'Y01').length, 1);
});

test('W04-AC-5 every link that selects a node keeps the filters of the view', async () => {
  const { renderExplorer, parseViewState } = await mod();
  const view = { node: 'Y01', tracks: ['now'], states: ['merged', 'held', 'waiting'] };
  const root = parse(renderExplorer(alpha(), view));
  const own = by(root, 'data-select');
  for (const id of ['M01', 'M02', 'R01', 'Y01']) assert.ok(own.some((a) => a.attrs['data-select'] === id), `a select link for ${id}`);
  for (const a of own) {
    const v = parseViewState(a.attrs.href);
    assert.deepEqual(v.tracks, view.tracks, a.attrs.href);
    assert.deepEqual(v.states, view.states, a.attrs.href);
    assert.ok(v.node, `${a.attrs.href} selects a node`);
  }
});

test('W04-AC-5 a hash with hostile or unknown values renders safely: nothing selected, nothing raw', async () => {
  const { renderExplorer, parseViewState } = await mod();
  const hash = '#/repo/acme/alpha?node=%3Cscript%3Ealert(1)%3C%2Fscript%3E&track=%3Cscript%3E&state=%22';
  const v = parseViewState(hash);
  assert.equal(v.node, '<script>alert(1)</script>');
  const html = renderExplorer(alpha(), v);
  assert.doesNotMatch(html, /<script/i);
  const root = parse(html);
  assert.equal(by(root, 'data-panel').length, 0);
  assert.equal(realNodes(root).length, 0, 'unknown tracks and states match no node');
});
