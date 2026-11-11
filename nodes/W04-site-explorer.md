# W04 — site-explorer

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | W03 | W05 | L |

**Owns:** `site/explorer/` (the layout, the graph queries, the explorer view), its tests in `site/test/`, the explorer's place in the repository view of `site/app.js`.
**Resolves:** #47

## Purpose
After this node each repository's page on the status site opens with its node graph as a picture rather than a table. The graph is a layered DAG with dependencies left to right, in one band per track, and nodes coloured by state. Clicking a node shows everything about it. Selecting a node highlights all it depends on and all that depends on it. The explorer marks what is ready next and the longest chain of work left. It shows the changes of open spec PRs as ghost nodes, and filters by track and state. It is drawn in plain SVG from the repository file (W01) with no library, and W03's node table stays below it.

## Tests
- `site/test/` (extended, `node:test`, run by `site/site.test.sh`):
  - the layout on the W01 fixture graph and on generated graphs (a chain, a diamond, a wide fan, 60 nodes): its invariants, its determinism, and that it rejects a cycle with a message;
  - the graph queries (upstream, downstream, ready next, the longest remaining chain, ghost nodes) on hand-made graphs with known answers;
  - the explorer's SVG and details panel, rendered to strings: the colours and legend, the details, the highlight, the filters, the ghosts;
  - the URL state.

## Changes
1. **Layout.** `site/explorer/layout.js` gives each node a column equal to the length of its longest dependency path, so every edge runs left to right. It gives each track a horizontal band, in the order the tracks first appear in the graph. Within a column and band it orders nodes to reduce edge crossings: start in graph order, then 4 passes of median ordering by neighbours. The same graph always gives the same positions. A cycle, or a dep naming no node, is shown as a message naming the nodes and is not drawn. *W04-AC-1.*
2. **Queries.** `site/explorer/graph.js` provides the following:
   - upstream (every transitive dep) and downstream (every transitive dependant) of a node;
   - ready next: the nodes in state `ready` or `held`;
   - the longest remaining chain: the longest dependency path through nodes not `merged`, counted in nodes, ties broken by graph order;
   - the ghosts: from each open spec PR's pending changes, the added nodes (with their deps as dashed edges), the changed nodes (marked, with the differing fields) and the removed nodes (struck through), each tagged with its PR's number.

   *W04-AC-2, W04-AC-4.*
3. **The view.** `site/explorer/view.js` draws the SVG as follows:
   - nodes as labelled boxes (ID and name), coloured by state with one colour per state, and a legend naming each;
   - a mark on ready-next nodes and a heavier stroke along the longest remaining chain;
   - the ghosts drawn dashed.

   Clicking a node selects it. The details panel shows:
   - its summary, size, track and state with its details, and its starts used;
   - its criteria;
   - its deps and unlocks, as links that select those nodes;
   - its PR, its question's first line and the issue where it is answered, and links to its spec on GitHub.

   A selection highlights the node, its upstream and its downstream (and their edges) and dims the rest. Clicking the background or pressing Escape clears it. Filters by track and by state hide the nodes they exclude and the edges touching them. The selection and the filters are kept in the URL hash (`#/repo/<owner>/<name>?node=<ID>&track=…&state=…`), so a link opens the same view. *W04-AC-3, W04-AC-5.*
4. **In the page.** The repository view of W03 shows the explorer above its node table. A node selected in either is selected in both. A new poll keeps the selection and the filters, and moves no node whose graph entry did not change. *W04-AC-6.*

## Gate
- **W04-AC-1** — For every test graph, every node's column is the length of its longest dependency path, and every edge goes from a lower column to a higher one. Each node is in its track's band, and the bands follow the tracks' order in the graph. Laying out the same graph twice gives identical positions. A graph with a cycle or a dep naming no node renders a message naming the nodes and no SVG. *Verify:* `site/site.test.sh`.
- **W04-AC-2** — On the hand-made graphs, upstream and downstream return exactly the transitive deps and dependants, ready next returns exactly the `ready` and `held` nodes, and the longest remaining chain is the known one (not-merged nodes only, ties by graph order). *Verify:* `site/site.test.sh`.
- **W04-AC-3** — The SVG colours each node by its state, one colour per state, with a legend naming every state present. It marks the ready-next nodes and the longest remaining chain. Selecting a node gives a details panel with its summary, size, track, state details, starts used, criteria, deps and unlocks (each a link selecting that node), PR, question and issue links and spec link. It highlights exactly the node, its upstream and downstream and their edges. *Verify:* `site/site.test.sh`.
- **W04-AC-4** — From the fixture's open spec PR, the explorer draws its added nodes dashed with their deps' edges, marks its changed nodes with the differing fields, and strikes through its removed nodes, each tagged with the PR's number and linking to it. *Verify:* `site/site.test.sh`.
- **W04-AC-5** — A track or state filter hides exactly the nodes it excludes and every edge touching them. The selection and filters round-trip through the URL hash: rendering from the hash gives the same view. *Verify:* `site/site.test.sh`.
- **W04-AC-6** — In the repository view, selecting a node in the table selects it in the explorer and the reverse. After new data in which one node's state changed, the selection and filters are kept, and every node whose graph entry is unchanged keeps its position. *Verify:* `site/site.test.sh`.

## Risks
- The layout is a simple layered one. A graph of a hundred nodes with long-range deps may still cross many edges and need a wide scroll. The 60-node test graph shows it renders, not that it reads well.
- The colours are chosen for state, not tested for colour blindness. The legend and the details panel name each state in text.
- How it looks in a real browser is not tested: the tests check the SVG's structure, not its pixels. The owner should look at it once on Pages after W03's first deploy.
