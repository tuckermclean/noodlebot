// W04-AC-1: the layout of a 60-node graph with real dependencies (the big() graph of explorer-layout.test.mjs has no
// edges: its LCG uses the low bits of a power-of-two modulus). The generator here is mulberry32, which mixes all bits.
// Same API as explorer-layout.test.mjs (see its header comment).
import test from 'node:test';
import assert from 'node:assert/strict';

const mod = async () => import('../explorer/layout.js');

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// 60 nodes in 3 tracks; each node depends on 0..3 earlier nodes, about a third of the picks reaching far back
const gen = () => {
  const r = mulberry32(20240607);
  const ri = (m) => Math.floor(r() * m);
  const tracks = ['now', 'later', 'ops'];
  const out = [];
  for (let i = 0; i < 60; i++) {
    const deps = new Set();
    if (i) {
      const k = i < 3 ? ri(2) : 1 + ri(3);
      for (let j = 0; j < k; j++) {
        const far = r() < 0.35;
        deps.add(`N${far ? ri(Math.max(1, Math.floor(i / 2))) : Math.max(0, i - 1 - ri(Math.min(i, 4)))}`);
      }
    }
    out.push({ id: `N${i}`, track: tracks[ri(3)], deps: [...deps], state: 'ready' });
  }
  return out;
};

function depths(nodes) {
  const by = new Map(nodes.map((x) => [x.id, x]));
  const memo = new Map();
  const d = (id) => {
    if (!memo.has(id)) memo.set(id, Math.max(0, ...by.get(id).deps.map((p) => d(p) + 1)));
    return memo.get(id);
  };
  return Object.fromEntries(nodes.map((x) => [x.id, d(x.id)]));
}

test('W04-AC-1 the generated 60-node graph has many edges and several columns (generator guard)', () => {
  const nodes = gen();
  assert.equal(nodes.length, 60);
  const edges = nodes.reduce((s, x) => s + x.deps.length, 0);
  const cols = new Set(Object.values(depths(nodes))).size;
  const longRange = nodes.filter((x) => x.deps.some((p) => Number(x.id.slice(1)) - Number(p.slice(1)) > 8)).length;
  assert.ok(edges > 40, `edges ${edges}`);
  assert.ok(cols > 3, `columns ${cols}`);
  assert.ok(longRange > 0, 'some long-range dependency');
  assert.equal(new Set(nodes.map((x) => x.track)).size, 3);
});

test('W04-AC-1 a generated 60-node graph: every node\'s column is the length of its longest dependency path', async () => {
  const { layout } = await mod();
  const nodes = gen();
  const r = layout(nodes);
  assert.equal(r.error, undefined);
  const want = depths(nodes);
  assert.deepEqual(Object.keys(r.positions).sort(), nodes.map((x) => x.id).sort());
  for (const x of nodes) assert.equal(r.positions[x.id].col, want[x.id], x.id);
});

test('W04-AC-1 a generated 60-node graph: every edge goes from a lower column to a higher one, and from a smaller x to a larger', async () => {
  const { layout } = await mod();
  const nodes = gen();
  const { positions } = layout(nodes);
  for (const x of nodes) for (const p of x.deps) {
    assert.ok(positions[p].col < positions[x.id].col, `${p} -> ${x.id} columns`);
    assert.ok(positions[p].x < positions[x.id].x, `${p} -> ${x.id} x`);
  }
});

test('W04-AC-1 a generated 60-node graph: each node is in its track\'s band, and the bands follow the tracks\' first appearance', async () => {
  const { layout } = await mod();
  const nodes = gen();
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

test('W04-AC-1 a generated 60-node graph: nodes of one column and band get distinct rows', async () => {
  const { layout } = await mod();
  const nodes = gen();
  const { positions } = layout(nodes);
  const seen = new Set();
  for (const x of nodes) {
    const p = positions[x.id];
    const k = `${p.col}/${p.band}/${p.row}`;
    assert.ok(!seen.has(k), `${x.id} shares ${k}`);
    seen.add(k);
  }
});

test('W04-AC-1 a generated 60-node graph: laying it out twice gives identical positions, and the input is unchanged', async () => {
  const { layout } = await mod();
  const nodes = gen();
  const before = JSON.stringify(nodes);
  const a = layout(nodes);
  const b = layout(gen());
  assert.ok(a.positions);
  assert.deepEqual(a, b);
  assert.equal(JSON.stringify(nodes), before);
});
