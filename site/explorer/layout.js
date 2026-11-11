// The explorer's layout: a column per node (its longest dependency path), a band per track, and an order within each
// column and band that reduces edge crossings. Pure and deterministic; the input is not changed.
const COL_W = 200;
const ROW_H = 64;
const BAND_PAD = 16;
const PASSES = 4;

// the ids of the nodes on a cycle (those left when the nodes nothing depends on, and the nodes with no deps, are peeled away)
function cycleIds(nodes) {
  let rest = nodes.map((x) => x.id);
  for (let changed = true; changed;) {
    const left = new Set(rest);
    const used = new Set(nodes.filter((x) => left.has(x.id)).flatMap((x) => x.deps.filter((d) => left.has(d))));
    const next = nodes.filter((x) => left.has(x.id) && used.has(x.id) && x.deps.some((d) => left.has(d))).map((x) => x.id);
    changed = next.length !== rest.length;
    rest = next;
  }
  return rest;
}

function columns(nodes) {
  const col = new Map();
  const todo = new Set(nodes.map((x) => x.id));
  const by = new Map(nodes.map((x) => [x.id, x]));
  while (todo.size) {
    const ready = [...todo].filter((id) => by.get(id).deps.every((d) => col.has(d)));
    if (!ready.length) return { error: `dependency cycle among: ${cycleIds(nodes).join(', ')}` };
    for (const id of ready) col.set(id, Math.max(0, ...by.get(id).deps.map((d) => col.get(d) + 1)));
    for (const id of ready) todo.delete(id);
  }
  return { col };
}

export function layout(nodes) {
  const ids = new Set(nodes.map((x) => x.id));
  for (const x of nodes) {
    for (const d of x.deps) if (!ids.has(d)) return { error: `${x.id} depends on ${d}, which is not a node` };
  }
  const { col, error } = columns(nodes);
  if (error) return { error };

  const tracks = [...new Set(nodes.map((x) => x.track))];
  const band = new Map(nodes.map((x) => [x.id, tracks.indexOf(x.track)]));
  const preds = new Map(nodes.map((x) => [x.id, x.deps]));
  const succs = new Map(nodes.map((x) => [x.id, []]));
  for (const x of nodes) for (const d of x.deps) succs.get(d).push(x.id);

  // cells[c][b] = ids in graph order; rank = a comparable vertical key, band-major
  const ncol = Math.max(-1, ...col.values()) + 1;
  const cells = Array.from({ length: ncol }, () => tracks.map(() => []));
  for (const x of nodes) cells[col.get(x.id)][band.get(x.id)].push(x.id);
  const rank = new Map();
  const rerank = () => cells.forEach((c) => c.forEach((cell, b) => cell.forEach((id, i) => rank.set(id, b * 1000 + i))));
  rerank();

  const median = (id, nb) => {
    const v = nb.get(id).map((o) => rank.get(o)).sort((a, b) => a - b);
    if (!v.length) return rank.get(id);
    const m = v.length >> 1;
    return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2;
  };
  const sweep = (order, nb) => {
    for (const c of order) {
      for (let b = 0; b < tracks.length; b++) {
        const keyed = cells[c][b].map((id, i) => ({ id, i, k: median(id, nb) }));
        keyed.sort((p, q) => p.k - q.k || p.i - q.i);
        cells[c][b] = keyed.map((e) => e.id);
      }
      rerank();
    }
  };
  const forward = cells.map((_, i) => i);
  for (let p = 0; p < PASSES; p++) {
    if (p % 2 === 0) sweep(forward, preds);
    else sweep([...forward].reverse(), succs);
  }

  const bands = [];
  const positions = {};
  let y = 0;
  tracks.forEach((track, b) => {
    const rows = Math.max(1, ...cells.map((c) => c[b].length));
    const height = rows * ROW_H + 2 * BAND_PAD;
    bands.push({ track, y, height });
    cells.forEach((c, ci) => c[b].forEach((id, row) => {
      positions[id] = { col: ci, band: b, row, x: ci * COL_W, y: y + BAND_PAD + row * ROW_H };
    }));
    y += height;
  });
  return { positions, bands };
}
