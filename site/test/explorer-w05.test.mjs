// W05-AC-6: links to a node the site has or does not have yet, through site/app.js createApp (as explorer-page.test.mjs
// drives it) for the repository route '#/repo/acme/alpha?node=<ID>'.
//   - buildHash('<o>/<n>', {node: ID}) is '#/repo/<o>/<n>?node=<ID>' (the form report.py writes).
//   - ID a node of the graph: selected (explorer and table), details shown (as W04).
//   - ID a ghost added by the fixture's open spec PR (acme/alpha #51 adds N01): selected, its details link the PR.
//     (the ghost's <g data-node="N01" data-ghost="added"> carries data-selected="true", and an <aside data-panel="N01"> is shown)
//   - ID in neither: the page shows, above the explorer, the note `No node <ID> in acme/alpha's published graph yet`
//     with the ID HTML-escaped (the text content of the note, HTML-escaped in the markup), and selects nothing
//     (no data-selected="true", no details panel).
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadFixture, clock, fakeFetch } from './helper.mjs';
import { parse, all, by } from './dom.mjs';

const MIN = 60000;
async function page(hash) {
  const app = await import('../app.js');
  const fx = loadFixture();
  const clk = clock(fx.manifest.seen * 1000 + MIN);
  const f = fakeFetch((c) => (c.url.startsWith('https://api.github.com/gists/')
    ? { status: 200, headers: { ETag: '"e1"' }, body: fx.gist } : { status: 404, body: '' }), clk);
  const location = { search: '?gist=g1', hash };
  const a = app.createApp({ location, fetch: f, now: clk.now, hidden: clk.hidden });
  await a.start();
  return a;
}
const explorer = (root) => by(root, 'data-explorer')[0];
const selected = (root) => all(explorer(root), (e) => 'data-node' in e.attrs && e.attrs['data-selected'] === 'true').map((e) => e.attrs['data-node']);
const links = (el) => all(el, (e) => e.tag === 'a');
const NOTE = (id) => `No node ${id} in acme/alpha's published graph yet`;

test('W05-AC-6 buildHash gives #/repo/<o>/<n>?node=<ID> for a node', async () => {
  const { buildHash } = await import('../explorer/view.js');
  assert.equal(buildHash('acme/alpha', { node: 'W05' }), '#/repo/acme/alpha?node=W05');
  assert.equal(buildHash('o/n', { node: 'M02' }), '#/repo/o/n?node=M02');
});

test('W05-AC-6 ?node= naming a node of the graph selects it and shows its details, with no note', async () => {
  const a = await page('#/repo/acme/alpha?node=M02');
  const html = a.render();
  const root = parse(html);
  assert.deepEqual(selected(root), ['M02']);
  assert.equal(by(explorer(root), 'data-panel', 'M02').length, 1);
  assert.ok(!html.includes('published graph yet'), 'no note for a node of the graph');
});

test('W05-AC-6 ?node= naming a ghost added by the open spec PR selects it and its details link the PR', async () => {
  const a = await page('#/repo/acme/alpha?node=N01');
  const html = a.render();
  const root = parse(html);
  assert.deepEqual(selected(root), ['N01'], 'the ghost is selected');
  const panel = by(explorer(root), 'data-panel', 'N01')[0];
  assert.ok(panel, 'its details panel is shown');
  assert.ok(links(panel).some((l) => l.attrs.href === 'https://github.com/acme/alpha/pull/51'), 'the panel links PR #51');
  assert.ok(!html.includes('published graph yet'), 'no note for a ghost');
});

test('W05-AC-6 ?node= naming an ID in neither shows the note above the explorer and selects nothing', async () => {
  const a = await page('#/repo/acme/alpha?node=Z99');
  const html = a.render();
  assert.ok(html.includes(NOTE('Z99')), `the note is shown: ${NOTE('Z99')}`);
  const i = html.indexOf(NOTE('Z99'));
  const j = html.indexOf('data-explorer="acme/alpha"');
  assert.ok(i >= 0 && j >= 0 && i < j, 'the note comes above the explorer');
  const root = parse(html);
  assert.deepEqual(selected(root), [], 'nothing is selected in the explorer');
  assert.equal(by(root, 'data-panel').length, 0, 'no details panel');
  assert.ok(by(root, 'data-node').every((e) => e.attrs['data-selected'] !== 'true'), 'no selected row either');
});

test('W05-AC-6 the ID in the note is HTML-escaped', async () => {
  const { buildHash } = await import('../explorer/view.js');
  const id = '<b>X"1';
  const a = await page(buildHash('acme/alpha', { node: id }));
  const html = a.render();
  assert.ok(!html.includes('<b>X'), 'the ID is not in the markup raw');
  assert.ok(html.includes('No node &lt;b&gt;X&quot;1 in acme/alpha&#39;s published graph yet')
    || html.includes('No node &lt;b&gt;X&quot;1 in acme/alpha\'s published graph yet'), 'the escaped ID is in the note');
  const root = parse(html);
  assert.deepEqual(selected(root), []);
  assert.equal(by(root, 'data-panel').length, 0);
});
