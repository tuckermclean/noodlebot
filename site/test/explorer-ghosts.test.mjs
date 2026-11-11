// W04-AC-4: the ghosts of open spec PRs: the query in site/explorer/graph.js and their drawing by the view
// (explorer/view.js, API in explorer-view.test.mjs). Each test imports the module itself.
//
// Expected from the implementation:
//   site/explorer/graph.js
//     export ghosts(specPrs) -> [ghost]   specPrs = the repo file's spec_prs[]: {number, branch, added: [entries],
//       changed: [{id, name|null, track|null, deps|null, summary|null}] (null = unchanged), removed: [ids]}.
//       One ghost per added, changed or removed node, in the order of specPrs, and within a PR added, changed, removed
//       (each in its list's order), each tagged with its PR's number `pr`; pure:
//         {kind: 'added',   pr, id, name, track, deps, summary}      (the added entry's fields)
//         {kind: 'changed', pr, id, fields: {<field>: <new value>}}  only the fields that differ, in the order
//                                                                    name, track, deps, summary
//         {kind: 'removed', pr, id}
//   The view, for a spec PR <n>, with link L = https://github.com/<repo>/pull/<n>:
//     added node    an extra node <g data-node="<ID>" data-ghost="added" data-pr="<n>" data-x data-y> (numbers; no
//                   data-state) whose <rect> has a non-empty stroke-dasharray, holding the ID and name, `#<n>` and <a href=L>;
//                   and, for each dep of it that is a node of the graph (an edge from another added node is optional), an edge <path data-edge="<dep>><ID>" data-ghost="added"
//                   data-pr="<n>" stroke-dasharray="..."> (dashed); real edges carry no data-ghost.
//     changed node  the node's own real <g> also carries data-ghost="changed" data-pr="<n>" and
//                   data-changed="<the differing fields, in the order name,track,deps,summary, joined by commas>",
//                   and holds `#<n>` and <a href=L>.
//     removed node  the node's own real <g> also carries data-ghost="removed" data-pr="<n>", holds an element with
//                   text-decoration="line-through", `#<n>` and <a href=L>.
//     A node with no ghost has no data-ghost, no data-pr, and a rect with no stroke-dasharray.
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadFixture } from './helper.mjs';
import { parse, all, by } from './dom.mjs';

const mod = async () => import('../explorer/graph.js');
const view = async () => import('../explorer/view.js');
const alpha = () => loadFixture().files['repo.acme.alpha.json'];
const links = (el) => all(el, (e) => e.tag === 'a');
const mk = (id, track, deps = [], state = 'waiting') => ({
  id, name: `${id.toLowerCase()}-name`, track, deps, unlocks: [], summary: `summary of ${id}`, size: null, has_spec: false,
  criteria: [], starts: 0, state, pr: null, started: null, text: null, url: null, mergeable: null, waiting_for: [],
});
const entry = (id, track, deps, name = `${id.toLowerCase()}-name`, summary = `summary of ${id}`) => ({ id, name, track, deps, summary });

const PRS = () => [
  { number: 7, branch: 'spec/a', added: [entry('X1', 'later', ['A']), entry('X2', 'now', ['X1', 'B'])],
    changed: [{ id: 'B', name: null, track: 'later', deps: null, summary: 'new words' }, { id: 'C', name: 'c-new', track: null, deps: ['A', 'B'], summary: null }],
    removed: ['D'] },
  { number: 9, branch: 'spec/b', added: [], changed: [], removed: ['C', 'B'] },
  { number: 11, branch: 'spec/empty', added: [], changed: [], removed: [] },
];

// ---- the query, on hand-made spec_prs with known answers
test('W04-AC-4 ghosts lists each added, changed and removed node tagged with its PR, in a known order', async () => {
  const { ghosts } = await mod();
  assert.deepEqual(ghosts(PRS()).map((g) => `${g.kind}:${g.pr}:${g.id}`),
    ['added:7:X1', 'added:7:X2', 'changed:7:B', 'changed:7:C', 'removed:7:D', 'removed:9:C', 'removed:9:B']);
});

test('W04-AC-4 an added ghost carries the entry: name, track, deps and summary', async () => {
  const { ghosts } = await mod();
  const g = ghosts(PRS()).find((x) => x.kind === 'added' && x.id === 'X2');
  assert.equal(g.pr, 7);
  assert.equal(g.name, 'x2-name');
  assert.equal(g.track, 'now');
  assert.deepEqual(g.deps, ['X1', 'B']);
  assert.equal(g.summary, 'summary of X2');
});

test('W04-AC-4 a changed ghost holds exactly the differing fields with their new values, in a fixed order', async () => {
  const { ghosts } = await mod();
  const gs = ghosts(PRS()).filter((x) => x.kind === 'changed');
  assert.deepEqual(gs.find((x) => x.id === 'B').fields, { track: 'later', summary: 'new words' });
  assert.deepEqual(gs.find((x) => x.id === 'C').fields, { name: 'c-new', deps: ['A', 'B'] });
  assert.deepEqual(Object.keys(gs.find((x) => x.id === 'C').fields), ['name', 'deps']);
});

test('W04-AC-4 a PR with no pending change gives no ghost, no PRs give none, and the input is not changed', async () => {
  const { ghosts } = await mod();
  assert.deepEqual(ghosts([]), []);
  assert.deepEqual(ghosts([{ number: 11, branch: 'spec/empty', added: [], changed: [], removed: [] }]), []);
  const before = JSON.stringify(PRS());
  const input = PRS();
  ghosts(input);
  assert.equal(JSON.stringify(input), before);
});

// ---- the view, on the fixture's open spec PR 51 (adds N01, changes R01 deps and Y01 track+summary, removes Z01)
const fixtureGhosts = async () => {
  const r = alpha();
  assert.equal(r.spec_prs.length, 1);
  assert.equal(r.spec_prs[0].number, 51);
  assert.deepEqual(r.spec_prs[0].added.map((n) => n.id), ['N01'], 'the fixture carries the spec branch (site.test.sh)');
  const { renderExplorer } = await view();
  return { r, root: parse(renderExplorer(r, {})) };
};
const PR = 'https://github.com/acme/alpha/pull/51';
const rectOf = (g) => all(g, (e) => e.tag === 'rect')[0];

test('W04-AC-4 the added node is drawn dashed, tagged #51 and linking to the PR, with its deps\' edges dashed', async () => {
  const { root } = await fixtureGhosts();
  const g = by(root, 'data-node', 'N01')[0];
  assert.ok(g, 'N01 is drawn');
  assert.equal(g.attrs['data-ghost'], 'added');
  assert.equal(g.attrs['data-pr'], '51');
  assert.ok(!('data-state' in g.attrs), 'no state: it is not a node of the graph');
  assert.ok(Number.isFinite(Number(g.attrs['data-x'])) && Number.isFinite(Number(g.attrs['data-y'])), 'it has a position');
  assert.ok(rectOf(g).attrs['stroke-dasharray'], 'dashed box');
  assert.ok(g.text.includes('N01') && g.text.includes('new-thing') && g.text.includes('#51'));
  assert.ok(links(g).some((a) => a.attrs.href === PR), 'links to the PR');
  const edge = by(root, 'data-edge', 'M01>N01');
  assert.equal(edge.length, 1, 'the edge of its dep');
  assert.equal(edge[0].attrs['data-ghost'], 'added');
  assert.equal(edge[0].attrs['data-pr'], '51');
  assert.ok(edge[0].attrs['stroke-dasharray'], 'dashed edge');
  assert.equal(by(root, 'data-edge').filter((e) => e.attrs['data-edge'].endsWith('>N01')).length, 1, 'no other edge into N01');
});

test('W04-AC-4 the changed nodes are marked with the differing fields, tagged #51 and linking to the PR', async () => {
  const { root } = await fixtureGhosts();
  const r01 = by(root, 'data-node', 'R01')[0];
  const y01 = by(root, 'data-node', 'Y01')[0];
  assert.equal(r01.attrs['data-ghost'], 'changed');
  assert.equal(r01.attrs['data-changed'], 'deps');
  assert.equal(y01.attrs['data-ghost'], 'changed');
  assert.equal(y01.attrs['data-changed'], 'track,summary');
  for (const g of [r01, y01]) {
    assert.equal(g.attrs['data-pr'], '51');
    assert.ok(g.attrs['data-state'], 'still the real node');
    assert.ok(g.text.includes('#51'));
    assert.ok(links(g).some((a) => a.attrs.href === PR), 'links to the PR');
  }
});

test('W04-AC-4 the removed node is struck through, tagged #51 and linking to the PR', async () => {
  const { root } = await fixtureGhosts();
  const z = by(root, 'data-node', 'Z01')[0];
  assert.equal(z.attrs['data-ghost'], 'removed');
  assert.equal(z.attrs['data-pr'], '51');
  assert.ok(by(z, 'text-decoration', 'line-through').length >= 1, 'struck through');
  assert.ok(z.text.includes('#51'));
  assert.ok(links(z).some((a) => a.attrs.href === PR), 'links to the PR');
});

test('W04-AC-4 only the nodes the PR touches are ghosts; the others are drawn as before, solid', async () => {
  const { r, root } = await fixtureGhosts();
  const tagged = by(root, 'data-ghost').filter((e) => 'data-node' in e.attrs).map((e) => `${e.attrs['data-node']}:${e.attrs['data-ghost']}`).sort();
  assert.deepEqual(tagged, ['N01:added', 'R01:changed', 'Y01:changed', 'Z01:removed']);
  for (const n of r.nodes.filter((x) => !['R01', 'Y01', 'Z01'].includes(x.id))) {
    const g = by(root, 'data-node', n.id)[0];
    assert.ok(!('data-pr' in g.attrs) && !('data-ghost' in g.attrs), `${n.id} has no ghost tag`);
    assert.ok(!rectOf(g).attrs['stroke-dasharray'], `${n.id} is solid`);
  }
  assert.ok(by(root, 'data-edge').filter((e) => !('data-ghost' in e.attrs)).every((e) => !e.attrs['stroke-dasharray']), 'real edges are solid');
});

test('W04-AC-4 two spec PRs are each drawn, tagged with their own number and link', async () => {
  const { renderExplorer } = await view();
  const nodes = [mk('A', 'now', [], 'merged'), mk('B', 'now', ['A']), mk('C', 'now', ['B']), mk('D', 'later', ['A'])];
  const prs = [
    { number: 7, branch: 'spec/a', added: [entry('X1', 'later', ['A']), entry('X2', 'now', ['X1', 'B'])], changed: [{ id: 'B', name: null, track: 'later', deps: null, summary: 'new words' }], removed: ['D'] },
    { number: 9, branch: 'spec/b', added: [], changed: [], removed: ['C'] },
  ];
  const root = parse(renderExplorer({ repo: 'acme/alpha', name: 'alpha', nodes, open_prs: [], spec_prs: prs }, {}));
  const tag = (id) => { const g = by(root, 'data-node', id)[0]; return `${g.attrs['data-ghost']}:${g.attrs['data-pr']}`; };
  assert.equal(tag('X1'), 'added:7');
  assert.equal(tag('X2'), 'added:7');
  assert.equal(tag('B'), 'changed:7');
  assert.equal(by(root, 'data-node', 'B')[0].attrs['data-changed'], 'track,summary');
  assert.equal(tag('D'), 'removed:7');
  assert.equal(tag('C'), 'removed:9');
  assert.ok(links(by(root, 'data-node', 'C')[0]).some((a) => a.attrs.href === 'https://github.com/acme/alpha/pull/9'));
  assert.ok(links(by(root, 'data-node', 'X2')[0]).some((a) => a.attrs.href === 'https://github.com/acme/alpha/pull/7'));
  const ghostEdges = by(root, 'data-edge').filter((e) => e.attrs['data-ghost'] === 'added').map((e) => e.attrs['data-edge']);
  for (const want of ['A>X1', 'B>X2']) assert.ok(ghostEdges.includes(want), `the dashed edge ${want}`);
  assert.ok(ghostEdges.every((e) => e.endsWith('>X1') || e.endsWith('>X2')), 'only the added nodes get dashed edges');
  assert.ok(!('data-ghost' in by(root, 'data-node', 'A')[0].attrs));
});

test('W04-AC-4 a ghost text from the data (a name, a summary) is escaped', async () => {
  const { renderExplorer } = await view();
  const nodes = [mk('A', 'now', [], 'merged')];
  const prs = [{ number: 5, branch: 'spec/<script>', added: [entry('X1', 'now', ['A'], '<script>alert(1)</script>', '"><img src=x>')], changed: [], removed: [] }];
  const html = renderExplorer({ repo: 'acme/alpha', name: 'alpha', nodes, open_prs: [], spec_prs: prs }, { node: 'A' });
  assert.doesNotMatch(html, /<script/i);
  assert.doesNotMatch(html, /<img/i);
});
