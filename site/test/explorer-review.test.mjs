// Review findings on slice 2 (W04-AC-3, W04-AC-4): the tests were weaker than the criteria.
//   - a changed node must show its differing fields on screen (text content, not the data-changed attribute), with its PR tag;
//     when selected, the details panel says that PR changes it, names the fields and links to the PR.
//   - clicking a node selects it: the node's <rect> (its box) is inside <a data-select="<ID>">, not only its label.
// API: see explorer-view.test.mjs. The element reader dom.mjs gives `text` = text content (tags and attributes excluded).
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadFixture } from './helper.mjs';
import { parse, all, by } from './dom.mjs';

const mod = async () => import('../explorer/view.js');
const alpha = () => loadFixture().files['repo.acme.alpha.json'];
const render = async (repo, view) => parse((await mod()).renderExplorer(repo, view));
const PR = 'https://github.com/acme/alpha/pull/51';
const CHANGED = { R01: ['deps'], Y01: ['track', 'summary'] };

test('W04-AC-4 a changed node shows on screen the PR tag #51 and each differing field', async () => {
  const root = await render(alpha(), {});
  for (const [id, fields] of Object.entries(CHANGED)) {
    const g = by(root, 'data-node', id)[0];
    assert.equal(g.attrs['data-ghost'], 'changed', `${id} is a changed ghost`);
    assert.ok(g.text.includes('#51'), `${id} shows #51 in its text: ${g.text}`);
    for (const f of fields) assert.ok(g.text.includes(f), `${id} text names the field ${f}: ${g.text}`);
  }
});

test('W04-AC-4 a changed node does not name fields it does not change', async () => {
  const root = await render(alpha(), {});
  const g = by(root, 'data-node', 'R01')[0];
  assert.ok(g.text.includes('deps'), `R01 text names deps: ${g.text}`);
  for (const f of ['track', 'summary']) assert.ok(!g.text.includes(f), `R01 text does not name ${f}: ${g.text}`);
});

test('W04-AC-4 the details panel of a changed node says PR #51 changes it, names the fields and links to the PR', async () => {
  for (const [id, fields] of Object.entries(CHANGED)) {
    const root = await render(alpha(), { node: id });
    const panel = by(root, 'data-panel', id)[0];
    assert.ok(panel, `panel of ${id}`);
    assert.ok(panel.text.includes('#51'), `${id} panel mentions #51: ${panel.text}`);
    for (const f of fields) assert.ok(panel.text.includes(f), `${id} panel names ${f}: ${panel.text}`);
    assert.ok(all(panel, (e) => e.tag === 'a' && e.attrs.href === PR).length >= 1, `${id} panel links to ${PR}`);
  }
});

test("W04-AC-3 each real node's box (rect) is inside its <a data-select=ID>, so a click on the box selects it", async () => {
  const r = alpha();
  const root = await render(r, {});
  for (const n of r.nodes) {
    const g = by(root, 'data-node', n.id)[0];
    const a = all(g, (e) => e.tag === 'a' && e.attrs['data-select'] === n.id)[0];
    assert.ok(a, `${n.id} has a select link`);
    assert.ok(all(a, (e) => e.tag === 'rect').length >= 1, `${n.id} rect is inside <a data-select>`);
  }
});
