// W04-AC-1: the explorer's layout, site/explorer/layout.js. Each test imports the module itself, so a missing
// module fails each case on its own line.
//
// Expected from the implementation:
//   site/explorer/layout.js   export layout(nodes) -> result
//     nodes   entries shaped like the repository file's nodes[] ({id, track, deps: [id...], state, ...}), in graph order
//     result  on success {positions, bands} and no `error`:
//       positions  {<id>: {col, band, row, x, y}}, one per node
//         col   the length (in edges) of the node's longest dependency path (0 with no deps)
//         band  the index into `bands` of the node's track
//         row   the node's order (0, 1, ...) among the nodes sharing its column and band, after the crossing reduction
//         x, y  numbers: the drawing position (x grows with col, so every edge runs left to right)
//       bands      [{track, y, height}], one per track, in the order the tracks first appear in the graph; each node's
//                  y lies in [band.y, band.y + band.height) of its band, and the bands do not overlap, top to bottom
//     on a cycle or a dep naming no node: {error: <message>} with no `positions` (nothing is drawn). The message
//     names the nodes involved: every node of a cycle; for a dangling dep both the node and the missing id.
//     Pure and deterministic: the same nodes always give deep-equal results; the input is not changed.
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadFixture } from './helper.mjs';

const mod = async () => import('../explorer/layout.js');
const n = (id, track, deps = [], state = 'ready') => ({ id, track, deps, state });

const chain = (len) => Array.from({ length: len }, (_, i) => n(`C${i}`, 'now', i ? [`C${i - 1}`] : []));
const diamond = () => [n('A', 'now'), n('B', 'now', ['A']), n('C', 'later', ['A']), n('D', 'now', ['B', 'C'])];
const fan = () => [n('R', 'now'), ...Array.from({ length: 12 }, (_, i) => n(`L${i}`, i % 2 ? 'later' : 'now', ['R'])),
  n('S', 'now', Array.from({ length: 12 }, (_, i) => `L${i}`))];
// 60 nodes in 3 tracks with deps on earlier nodes (some long-range), from a fixed pseudo-random sequence
const big = () => {
  let s = 12345;
  const rnd = (m) => { s = (s * 1103515245 + 12345) % 2147483648; return s % m; };
  const tracks = ['now', 'later', 'ops'];
  const out = [];
  for (let i = 0; i < 60; i++) {
    const deps = new Set();
    if (i) for (let k = rnd(4); k > 0; k--) deps.add(`N${rnd(i)}`);
    out.push(n(`N${i}`, tracks[rnd(3)], [...deps]));
  }
  return out;
};
const fixtureNodes = () => loadFixture().files['repo.acme.alpha.json'].nodes;

// the longest dependency path (in edges) of each node, computed here independently
function depths(nodes) {
  const by = new Map(nodes.map((x) => [x.id, x]));
  const memo = new Map();
  const d = (id) => {
    if (!memo.has(id)) memo.set(id, Math.max(0, ...by.get(id).deps.map((p) => d(p) + 1)));
    return memo.get(id);
  };
  return Object.fromEntries(nodes.map((x) => [x.id, d(x.id)]));
}

const graphs = () => [
  ['the W01 fixture graph', fixtureNodes()],
  ['a chain', chain(7)],
  ['a diamond', diamond()],
  ['a wide fan', fan()],
  ['a 60-node graph', big()],
];

for (const name of ['the W01 fixture graph', 'a chain', 'a diamond', 'a wide fan', 'a 60-node graph']) {
  const get = () => graphs().find((g) => g[0] === name)[1];

  test(`W04-AC-1 ${name}: every node's column is the length of its longest dependency path`, async () => {
    const { layout } = await mod();
    const nodes = get();
    const r = layout(nodes);
    assert.equal(r.error, undefined);
    const want = depths(nodes);
    assert.deepEqual(Object.keys(r.positions).sort(), nodes.map((x) => x.id).sort());
    for (const x of nodes) assert.equal(r.positions[x.id].col, want[x.id], x.id);
  });

  test(`W04-AC-1 ${name}: every edge goes from a lower column to a higher one, and from a smaller x to a larger`, async () => {
    const { layout } = await mod();
    const nodes = get();
    const { positions } = layout(nodes);
    for (const x of nodes) for (const p of x.deps) {
      assert.ok(positions[p].col < positions[x.id].col, `${p} -> ${x.id} columns`);
      assert.ok(positions[p].x < positions[x.id].x, `${p} -> ${x.id} x`);
    }
  });

  test(`W04-AC-1 ${name}: each node is in its track's band, and the bands follow the tracks' first appearance`, async () => {
    const { layout } = await mod();
    const nodes = get();
    const { positions, bands } = layout(nodes);
    const tracks = [...new Set(nodes.map((x) => x.track))];
    assert.deepEqual(bands.map((b) => b.track), tracks);
    for (let i = 1; i < bands.length; i++) assert.ok(bands[i - 1].y + bands[i - 1].height <= bands[i].y, 'bands overlap');
    for (const x of nodes) {
      const p = positions[x.id];
      assert.equal(p.band, tracks.indexOf(x.track), x.id);
      assert.ok(p.y >= bands[p.band].y && p.y < bands[p.band].y + bands[p.band].height, `${x.id} y inside its band`);
    }
  });

  test(`W04-AC-1 ${name}: nodes of one column and band get distinct rows`, async () => {
    const { layout } = await mod();
    const nodes = get();
    const { positions } = layout(nodes);
    const seen = new Set();
    for (const x of nodes) {
      const p = positions[x.id];
      const k = `${p.col}/${p.band}/${p.row}`;
      assert.ok(!seen.has(k), `${x.id} shares ${k}`);
      seen.add(k);
    }
  });

  test(`W04-AC-1 ${name}: laying it out twice gives identical positions, and the input is unchanged`, async () => {
    const { layout } = await mod();
    const nodes = get();
    const before = JSON.stringify(nodes);
    const a = layout(nodes);
    const b = layout(get());
    assert.ok(a.positions);
    assert.deepEqual(a, b);
    assert.equal(JSON.stringify(nodes), before);
  });
}

test('W04-AC-1 the fixture graph has the known columns', async () => {
  const { layout } = await mod();
  const { positions } = layout(fixtureNodes());
  assert.equal(positions.M01.col, 0);
  assert.equal(positions.R01.col, 1);
  assert.equal(positions.Y01.col, 1);
  assert.equal(positions.Z01.col, 2);
  assert.equal(positions.Q02.band, 1);
});

test('W04-AC-1 a chain of 7 spans columns 0 to 6', async () => {
  const { layout } = await mod();
  const { positions } = layout(chain(7));
  assert.deepEqual(Object.values(positions).map((p) => p.col), [0, 1, 2, 3, 4, 5, 6]);
});

test('W04-AC-1 a node with a short and a long path to it sits in the column of the long one', async () => {
  const { layout } = await mod();
  const { positions } = layout([n('A', 't'), n('B', 't', ['A']), n('C', 't', ['B']), n('D', 't', ['A', 'C'])]);
  assert.equal(positions.D.col, 3);
});

test('W04-AC-1 a cycle gives a message naming its nodes and no layout', async () => {
  const { layout } = await mod();
  const r = layout([n('A', 't'), n('X1', 't', ['A', 'X3']), n('X2', 't', ['X1']), n('X3', 't', ['X2']), n('B', 't', ['A'])]);
  assert.equal(typeof r.error, 'string');
  for (const id of ['X1', 'X2', 'X3']) assert.ok(r.error.includes(id), `message names ${id}: ${r.error}`);
  assert.equal(r.positions, undefined);
});

test('W04-AC-1 a node depending on itself is a cycle naming it', async () => {
  const { layout } = await mod();
  const r = layout([n('A', 't'), n('SELF', 't', ['SELF'])]);
  assert.equal(typeof r.error, 'string');
  assert.ok(r.error.includes('SELF'));
  assert.equal(r.positions, undefined);
});

test('W04-AC-1 a dep naming no node gives a message naming the node and the missing id, and no layout', async () => {
  const { layout } = await mod();
  const r = layout([n('A', 't'), n('B', 't', ['A', 'GONE9'])]);
  assert.equal(typeof r.error, 'string');
  assert.ok(r.error.includes('B') && r.error.includes('GONE9'), r.error);
  assert.equal(r.positions, undefined);
});
