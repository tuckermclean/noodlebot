// W04-AC-6: the explorer in the repository view of the page, through site/app.js createApp (as app.test.mjs drives it,
// with the fake fetch and clock of helper.mjs). Each test imports the module itself. The explorer's API is in
// explorer-view.test.mjs and explorer-url.test.mjs.
//
// Expected from the implementation (app.render() for a hash '#/repo/<owner>/<name>[?node=..&track=..&state=..]'):
//   - data-view="repo" as before; the page holds the explorer root (<section data-explorer="<owner>/<name>">, from
//     renderExplorer with the view state parsed from the hash) BEFORE the node table <table data-table="nodes">.
//   - the selection lives in the hash's node= and nowhere else, so both views show the same one:
//       explorer  the real node's <g data-node data-state data-selected="true|false">
//       table     each row <tr data-node="<ID>" data-selected="true|false"> (true only for the selected node)
//   - each table row also holds <a data-select="<ID>" href="<buildHash(repo, {...view, node: ID})>"> (the explorer's
//     nodes hold the same kind of link): following a link means setting location.hash to its href.
//   - the table still lists every node of the repository, whatever the filters (they filter the explorer only).
//   - a new poll changes nothing but what the new data changes: the hash, so the selection and filters, are untouched,
//     and a node whose graph entry (id, name, track, deps, summary, ...) did not change keeps its data-x / data-y.
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadFixture, clock, fakeFetch, gistBody } from './helper.mjs';
import { parse, all, by } from './dom.mjs';

const MIN = 60000;
const ok = (body, etag) => ({ status: 200, headers: { ETag: etag }, body });
const REPO_FILE = 'repo.acme.alpha.json';

async function page({ hash = '', second } = {}) {
  const app = await import('../app.js');
  const fx = loadFixture();
  const clk = clock(fx.manifest.seen * 1000 + MIN);
  const f = fakeFetch((c, n) => {
    if (!c.url.startsWith('https://api.github.com/gists/')) return { status: 404, body: '' };
    return n === 1 || !second ? ok(fx.gist, '"e1"') : ok(gistBody(fx, { mutate: second }), '"e2"');
  }, clk);
  const location = { search: '?gist=g1', hash };
  const a = app.createApp({ location, fetch: f, now: clk.now, hidden: clk.hidden });
  await a.start();
  return { a, f, clk, fx, location };
}
const view = (a) => parse(a.render());
const explorer = (root) => by(root, 'data-explorer')[0];
const exNodes = (root) => by(explorer(root), 'data-node').filter((g) => 'data-state' in g.attrs);
const rows = (root) => all(by(root, 'data-table', 'nodes')[0], (e) => e.tag === 'tr' && 'data-node' in e.attrs);
const selectedIn = (root) => ({
  explorer: exNodes(root).filter((g) => g.attrs['data-selected'] === 'true').map((g) => g.attrs['data-node']),
  table: rows(root).filter((r) => r.attrs['data-selected'] === 'true').map((r) => r.attrs['data-node']),
});

test('W04-AC-6 the repository view shows the explorer above the node table', async () => {
  const { a, location, fx } = await page({ hash: '#/repo/acme/alpha' });
  const html = a.render();
  assert.ok(html.includes('data-view="repo"'));
  const i = html.indexOf('data-explorer="acme/alpha"');
  const j = html.indexOf('data-table="nodes"');
  assert.ok(i >= 0 && j >= 0 && i < j, 'the explorer comes first');
  const root = view(a);
  assert.equal(all(explorer(root), (e) => e.tag === 'svg').length, 1);
  assert.equal(rows(root).length, fx.files[REPO_FILE].nodes.length, 'the table lists every node');
  assert.equal(exNodes(root).length, fx.files[REPO_FILE].nodes.length, 'the explorer draws every node');
  location.hash = '#/repo/acme/bravo';
  assert.ok(a.render().includes('data-explorer="acme/bravo"'), 'every repository has its own explorer');
});

test('W04-AC-6 a node named in the hash is selected in the explorer and in the table, and in no other row', async () => {
  const { a, location } = await page({ hash: '#/repo/acme/alpha' });
  assert.deepEqual(selectedIn(view(a)), { explorer: [], table: [] }, 'no selection to begin with');
  assert.ok(rows(view(a)).every((r) => r.attrs['data-selected'] === 'false'));
  for (const id of ['M02', 'Z01', 'Q01']) {
    location.hash = `#/repo/acme/alpha?node=${id}`;
    assert.deepEqual(selectedIn(view(a)), { explorer: [id], table: [id] }, id);
    assert.equal(by(explorer(view(a)), 'data-panel', id).length, 1, 'and its details are shown');
  }
});

test('W04-AC-6 selecting a node in the table selects it in the explorer', async () => {
  const { a, location } = await page({ hash: '#/repo/acme/alpha?track=now,later&state=merged,held,waiting,failed' });
  const { buildHash } = await import('../explorer/view.js');
  const row = rows(view(a)).find((r) => r.attrs['data-node'] === 'F01');
  const link = by(row, 'data-select', 'F01')[0];
  assert.ok(link, 'the row has a select link');
  assert.equal(link.attrs.href, buildHash('acme/alpha', { node: 'F01', tracks: ['now', 'later'], states: ['merged', 'held', 'waiting', 'failed'] }), 'it keeps the filters');
  location.hash = link.attrs.href;
  assert.deepEqual(selectedIn(view(a)), { explorer: ['F01'], table: ['F01'] });
});

test('W04-AC-6 selecting a node in the explorer selects it in the table', async () => {
  const { a, location } = await page({ hash: '#/repo/acme/alpha?node=M01&track=now&state=merged,held,waiting,failed' });
  const g = exNodes(view(a)).find((x) => x.attrs['data-node'] === 'F01');
  const link = by(g, 'data-select', 'F01')[0];
  assert.ok(link, 'the node has a select link');
  location.hash = link.attrs.href;
  const root = view(a);
  assert.deepEqual(selectedIn(root), { explorer: ['F01'], table: ['F01'] });
  assert.deepEqual(exNodes(root).map((x) => x.attrs['data-node']).sort(), ['F01', 'M01', 'M02', 'R01', 'Y01'], 'the filters are kept');
  assert.equal(rows(root).length, 11, 'the table is not filtered');
});

const FILTER = '#/repo/acme/alpha?node=Y01&track=now&state=merged,held,waiting,pending,ready,pr-open,question,answered,waiting-pr,running';
const posOf = (root) => Object.fromEntries(by(explorer(root), 'data-node').map((g) => [g.attrs['data-node'], `${g.attrs['data-x']},${g.attrs['data-y']}`]));
const changeY01 = (g) => {
  const f = g.files[REPO_FILE];
  const r = JSON.parse(f.content);
  const y = r.nodes.find((n) => n.id === 'Y01');
  y.state = 'ready';
  y.waiting_for = [];
  f.content = JSON.stringify(r);
};

test('W04-AC-6 after new data in which a node changed state, the selection and the filters are kept', async () => {
  const { a, f, clk, location } = await page({ hash: FILTER, second: changeY01 });
  const before = view(a);
  assert.equal(exNodes(before).find((g) => g.attrs['data-node'] === 'Y01').attrs['data-state'], 'waiting');
  const shown = exNodes(before).map((g) => g.attrs['data-node']).sort();
  assert.ok(shown.length > 0 && shown.length < 11, 'the filters hide some nodes');
  clk.advance(MIN + 1000);
  assert.equal(await a.tick(), true, 'a second poll');
  assert.equal(f.api().length, 2);
  assert.equal(location.hash, FILTER, 'the hash is untouched');
  const after = view(a);
  assert.equal(exNodes(after).find((g) => g.attrs['data-node'] === 'Y01').attrs['data-state'], 'ready', 'the new data is shown');
  assert.equal(by(after, 'data-legend', 'ready').length, 1, 'and its state is in the legend');
  assert.deepEqual(selectedIn(after), { explorer: ['Y01'], table: ['Y01'] }, 'the selection is kept');
  assert.deepEqual(exNodes(after).map((g) => g.attrs['data-node']).sort(), shown, 'the filters are kept');
  assert.equal(by(after, 'data-panel', 'Y01').length, 1);
});

test('W04-AC-6 after new data every node whose graph entry is unchanged keeps its position', async () => {
  for (const hash of [FILTER, '#/repo/acme/alpha']) {
    const { a, clk } = await page({ hash, second: changeY01 });
    const before = posOf(view(a));
    assert.ok(Object.keys(before).length >= 5);
    for (const [id, p] of Object.entries(before)) assert.ok(/^-?[\d.]+,-?[\d.]+$/.test(p), `${id} has a position`);
    clk.advance(MIN + 1000);
    assert.equal(await a.tick(), true);
    const after = view(a);
    assert.equal(exNodes(after).find((g) => g.attrs['data-node'] === 'Y01').attrs['data-state'], 'ready', 'the new data is in');
    assert.deepEqual(posOf(after), before, `${hash}: no node moved`);
  }
});

test('W04-AC-6 a hash with hostile values renders the repository page with nothing raw', async () => {
  const { a } = await page({ hash: '#/repo/acme/alpha?node=%3Cscript%3Ealert(1)%3C%2Fscript%3E&track=%22' });
  const html = a.render();
  assert.ok(html.includes('data-view="repo"'));
  assert.ok(html.includes('data-explorer="acme/alpha"'), 'the explorer is there');
  assert.doesNotMatch(html, /<script/i);
});
