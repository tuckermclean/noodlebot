// The explorer's graph queries over a repository file's nodes[] ({id, track, deps, state, ...}). Pure; the input is not
// changed. Results list ids in graph order.
const inOrder = (nodes, set) => nodes.map((x) => x.id).filter((id) => set.has(id));

// every id reachable from `id` by `next` (never `id` itself, even when a cycle leads back to it)
function reach(id, next) {
  const seen = new Set();
  const stack = [id];
  while (stack.length) {
    for (const o of next(stack.pop())) if (!seen.has(o)) { seen.add(o); stack.push(o); }
  }
  seen.delete(id);
  return seen;
}

export function upstream(nodes, id) {
  const by = new Map(nodes.map((x) => [x.id, x]));
  return inOrder(nodes, reach(id, (i) => (by.get(i) ? by.get(i).deps : [])));
}

export function downstream(nodes, id) {
  return inOrder(nodes, reach(id, (i) => nodes.filter((x) => x.deps.includes(i)).map((x) => x.id)));
}

export function readyNext(nodes) {
  return nodes.filter((x) => x.state === 'ready' || x.state === 'held').map((x) => x.id);
}

// the longest dependency path through not-merged nodes, in nodes; ties go to the path first in graph order
export function longestChain(nodes) {
  const pos = new Map(nodes.map((x, i) => [x.id, i]));
  const open = new Map(nodes.filter((x) => x.state !== 'merged').map((x) => [x.id, x]));
  const memo = new Map(); // id -> best chain ending at id
  const better = (a, b) => {
    if (a.length !== b.length) return a.length > b.length;
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return pos.get(a[i]) < pos.get(b[i]);
    return false;
  };
  const chainTo = (id) => {
    if (!memo.has(id)) {
      memo.set(id, [id]); // guards a cycle
      let best = [];
      for (const d of open.get(id).deps) {
        if (!open.has(d)) continue;
        const c = chainTo(d);
        if (better(c, best)) best = c;
      }
      memo.set(id, [...best, id]);
    }
    return memo.get(id);
  };
  let best = [];
  for (const id of open.keys()) {
    const c = chainTo(id);
    if (better(c, best)) best = c;
  }
  return best;
}

// The ghosts of the open spec PRs (spec_prs[]): one per added, changed or removed node, in the order of the PRs and,
// within a PR, added, changed, removed; each tagged with its PR's number. A changed ghost holds only the fields that differ.
export function ghosts(specPrs) {
  const out = [];
  for (const p of specPrs || []) {
    for (const a of p.added || []) out.push({ kind: 'added', pr: p.number, id: a.id, name: a.name, track: a.track, deps: a.deps, summary: a.summary });
    for (const c of p.changed || []) {
      const fields = {};
      for (const f of ['name', 'track', 'deps', 'summary']) if (c[f] !== null && c[f] !== undefined) fields[f] = c[f];
      out.push({ kind: 'changed', pr: p.number, id: c.id, fields });
    }
    for (const id of p.removed || []) out.push({ kind: 'removed', pr: p.number, id });
  }
  return out;
}
