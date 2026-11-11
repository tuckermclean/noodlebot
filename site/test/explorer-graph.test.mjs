// W04-AC-2: the explorer's graph queries, site/explorer/graph.js. Each test imports the module itself.
//
// Expected from the implementation (nodes are entries shaped like the repository file's nodes[]:
// {id, track, deps: [id...], state, ...}, in graph order; every query is pure and leaves the input unchanged):
//   site/explorer/graph.js
//     export upstream(nodes, id)   -> string[]  the IDs of all transitive deps of `id` (not `id` itself), in graph order
//     export downstream(nodes, id) -> string[]  the IDs of all transitive dependants of `id` (not `id`), in graph order
//     export readyNext(nodes)      -> string[]  the IDs of the nodes in state `ready` or `held`, in graph order
//     export longestChain(nodes)   -> string[]  the longest dependency path through nodes whose state is not `merged`
//                                    only, counted in nodes, from its first node (a dep) to its last, as IDs; ties
//                                    go to the path that comes first in graph order (compare the paths' IDs by
//                                    their positions in the graph, element by element); [] when every node is merged.
import test from 'node:test';
import assert from 'node:assert/strict';

const mod = async () => import('../explorer/graph.js');
const n = (id, deps = [], state = 'waiting') => ({ id, track: 'now', deps, state });
const sorted = (a) => [...a].sort();

// A <- B <- D, A <- C <- D, D <- E, F alone (deps point left)
const G1 = () => [n('A'), n('B', ['A']), n('C', ['A']), n('D', ['B', 'C']), n('E', ['D']), n('F')];

test('W04-AC-2 upstream returns exactly the transitive deps', async () => {
  const { upstream } = await mod();
  assert.deepEqual(sorted(upstream(G1(), 'E')), ['A', 'B', 'C', 'D']);
  assert.deepEqual(sorted(upstream(G1(), 'D')), ['A', 'B', 'C']);
  assert.deepEqual(sorted(upstream(G1(), 'B')), ['A']);
});

test('W04-AC-2 upstream of a node with no deps is empty, and does not include the node itself', async () => {
  const { upstream } = await mod();
  assert.deepEqual(upstream(G1(), 'A'), []);
  assert.deepEqual(upstream(G1(), 'F'), []);
  assert.ok(!upstream(G1(), 'D').includes('D'));
});

test('W04-AC-2 downstream returns exactly the transitive dependants', async () => {
  const { downstream } = await mod();
  assert.deepEqual(sorted(downstream(G1(), 'A')), ['B', 'C', 'D', 'E']);
  assert.deepEqual(sorted(downstream(G1(), 'B')), ['D', 'E']);
  assert.deepEqual(sorted(downstream(G1(), 'D')), ['E']);
});

test('W04-AC-2 downstream of a node nothing depends on is empty, and does not include the node itself', async () => {
  const { downstream } = await mod();
  assert.deepEqual(downstream(G1(), 'E'), []);
  assert.deepEqual(downstream(G1(), 'F'), []);
  assert.ok(!downstream(G1(), 'A').includes('A'));
});

test('W04-AC-2 upstream and downstream list each node once, in graph order, when paths converge', async () => {
  const { upstream, downstream } = await mod();
  assert.deepEqual(upstream(G1(), 'E'), ['A', 'B', 'C', 'D']);
  assert.deepEqual(downstream(G1(), 'A'), ['B', 'C', 'D', 'E']);
});

test('W04-AC-2 upstream and downstream follow deps that point later in the graph order', async () => {
  const { upstream, downstream } = await mod();
  const g = [n('Z', ['Y']), n('Y', ['X']), n('X'), n('W', ['X'])];
  assert.deepEqual(sorted(upstream(g, 'Z')), ['X', 'Y']);
  assert.deepEqual(sorted(downstream(g, 'X')), ['W', 'Y', 'Z']);
});

test('W04-AC-2 queries leave the input unchanged', async () => {
  const { upstream, downstream, readyNext, longestChain } = await mod();
  const g = G1();
  const before = JSON.stringify(g);
  upstream(g, 'E'); downstream(g, 'A'); readyNext(g); longestChain(g);
  assert.equal(JSON.stringify(g), before);
});

test('W04-AC-2 ready next returns exactly the ready and held nodes', async () => {
  const { readyNext } = await mod();
  const states = ['merged', 'ready', 'held', 'running', 'failed', 'question', 'answered', 'waiting-pr', 'pr-open', 'waiting'];
  const g = states.map((s, i) => n(`N${i}`, [], s));
  assert.deepEqual(readyNext(g), ['N1', 'N2']);
});

test('W04-AC-2 ready next is empty when no node is ready or held', async () => {
  const { readyNext } = await mod();
  assert.deepEqual(readyNext([n('A', [], 'merged'), n('B', ['A'], 'running'), n('C', ['A'], 'waiting')]), []);
  assert.deepEqual(readyNext([]), []);
});

test('W04-AC-2 ready next keeps graph order', async () => {
  const { readyNext } = await mod();
  assert.deepEqual(readyNext([n('Z', [], 'held'), n('M', [], 'merged'), n('A', [], 'ready')]), ['Z', 'A']);
});

test('W04-AC-2 the longest remaining chain is the longest path through not-merged nodes, counted in nodes', async () => {
  const { longestChain } = await mod();
  // M1 and M2 are merged; the open nodes form A -> B -> C and a shorter D -> C
  const g = [n('M1', [], 'merged'), n('M2', ['M1'], 'merged'), n('A', ['M2']), n('B', ['A']), n('D', ['M1']), n('C', ['B', 'D'])];
  assert.deepEqual(longestChain(g), ['A', 'B', 'C']);
});

test('W04-AC-2 merged nodes do not lengthen the chain: a long merged path loses to a shorter open one', async () => {
  const { longestChain } = await mod();
  // counting merged nodes, M1 -> M2 -> M3 -> X would be 4; the open nodes give P -> Q -> R (3) and X alone (1)
  const g = [n('M1', [], 'merged'), n('M2', ['M1'], 'merged'), n('M3', ['M2'], 'merged'), n('X', ['M3']),
    n('P'), n('Q', ['P']), n('R', ['Q'])];
  assert.deepEqual(longestChain(g), ['P', 'Q', 'R']);
});

test('W04-AC-2 a merged node in the middle of a path breaks it', async () => {
  const { longestChain } = await mod();
  // A -> M (merged) -> B: through open nodes only, A and B are separate chains of 1; A comes first
  const g = [n('A'), n('M', ['A'], 'merged'), n('B', ['M'])];
  assert.deepEqual(longestChain(g), ['A']);
});

test('W04-AC-2 ties for the longest chain go to the one first in graph order', async () => {
  const { longestChain } = await mod();
  const g = [n('A'), n('B'), n('C', ['B']), n('D', ['A'])];
  assert.deepEqual(longestChain(g), ['A', 'D']);
  const h = [n('B'), n('A'), n('D', ['A']), n('C', ['B'])];
  assert.deepEqual(longestChain(h), ['B', 'C']);
});

test('W04-AC-2 ties between paths that share their end go to the first in graph order', async () => {
  const { longestChain } = await mod();
  const g = [n('A'), n('B'), n('C', ['B', 'A'])];
  assert.deepEqual(longestChain(g), ['A', 'C']);
});

test('W04-AC-2 with no dependencies at all the chain is the first node; with all merged it is empty', async () => {
  const { longestChain } = await mod();
  assert.deepEqual(longestChain([n('A'), n('B'), n('C')]), ['A']);
  assert.deepEqual(longestChain([n('A', [], 'merged'), n('B', ['A'], 'merged')]), []);
  assert.deepEqual(longestChain([]), []);
});

test('W04-AC-2 the longest remaining chain is found when deps point later in the graph order', async () => {
  const { longestChain } = await mod();
  const g = [n('C', ['B']), n('B', ['A']), n('A'), n('M', [], 'merged')];
  assert.deepEqual(longestChain(g), ['A', 'B', 'C']);
});
