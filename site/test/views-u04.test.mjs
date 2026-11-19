// U04-AC-4: the node table of the repository view (site/views.js renderRepo) says whether a node with an open PR is
// ready to merge. Each test renders a repository file of nodes it builds (the fixture's alpha file with its node list
// replaced) and reads the row of one node (the <tr data-node="<ID>"> up to its </tr>), never the whole page.
//
// Expected from the implementation, per row:
//   state "pr-open", merge_ready true   the row says "ready to merge" and not "still being worked on"; when merge_why
//                                       is a string it is in the row too, escaped (&lt;script&gt;, never <script>);
//   state "pr-open", merge_ready false  the row says "still being worked on" and its merge_why, escaped, and not
//                                       "ready to merge";
//   any other state (merge_ready and merge_why null): neither text.
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadFixture } from './helper.mjs';

const MIN = 60000;
const X = '<script>alert(1)</script>';
const XE = '&lt;script&gt;alert(1)&lt;/script&gt;';
const node = (id, state, extra = {}) => ({
  id, name: `thing-${id.toLowerCase()}`, track: 'now', deps: [], unlocks: [], summary: 's', size: null, has_spec: false,
  criteria: [], starts: 1, state, pr: null, started: null, text: null, url: null, mergeable: null, waiting_for: [],
  merge_ready: null, merge_why: null, ...extra,
});
const open = (id, merge_ready, merge_why) => node(id, 'pr-open', { pr: 77, mergeable: 'MERGEABLE', merge_ready, merge_why });

async function render(nodes) {
  const views = await import('../views.js');
  const fx = loadFixture();
  const files = JSON.parse(JSON.stringify(fx.files));
  files['repo.acme.alpha.json'].nodes = nodes;
  const data = { manifest: fx.manifest, files };
  const ctx = { now: fx.manifest.seen * 1000 + MIN, lastSuccess: fx.manifest.seen * 1000 + MIN, repo: 'acme/alpha' };
  const html = views.renderRepo(data, ctx);
  return (id) => {
    const m = html.match(new RegExp(`<tr[^>]*data-node="${id}"[^>]*>[\\s\\S]*?</tr>`));
    assert.ok(m, `a row for ${id}`);
    return m[0];
  };
}
const plain = (h) => h.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ');
const READY = /ready to merge/;
const WORKED = /still being worked on/;

test('U04-AC-4 a pr-open node with merge_ready true and no merge_why shows "ready to merge" and not "still being worked on"', async () => {
  const row = await render([open('U01', true, null)]);
  assert.match(plain(row('U01')), READY);
  assert.doesNotMatch(plain(row('U01')), WORKED);
});

test('U04-AC-4 a pr-open node with merge_ready true shows its merge_why, escaped, next to "ready to merge"', async () => {
  const row = await render([open('U02', true, `the forge has not said whether it merges cleanly ${X}`)]);
  const h = row('U02');
  assert.match(plain(h), READY);
  assert.doesNotMatch(plain(h), WORKED);
  assert.ok(h.includes(`the forge has not said whether it merges cleanly ${XE}`), 'the note, escaped');
  assert.ok(!h.includes(X) && !/<script/i.test(h), 'no raw <script');
});

test('U04-AC-4 a pr-open node with merge_ready false shows "still being worked on" and its merge_why, escaped', async () => {
  const row = await render([open('U03', false, `CI failed on its head ${X} and "quoted"`)]);
  const h = row('U03');
  assert.match(plain(h), WORKED);
  assert.doesNotMatch(plain(h), READY);
  assert.ok(h.includes(`CI failed on its head ${XE} and &quot;quoted&quot;`), 'the reason, escaped');
  assert.ok(!h.includes(X) && !/<script/i.test(h), 'no raw <script');
});

test('U04-AC-4 each row shows its own text: a ready, a ready with a note and a not ready node in one table', async () => {
  const row = await render([open('U04', true, null), open('U05', false, 'it conflicts with its base'), open('U06', true, 'forge note')]);
  assert.match(plain(row('U04')), READY);
  assert.doesNotMatch(plain(row('U04')), /conflicts with its base|forge note|still being/);
  assert.match(plain(row('U05')), WORKED);
  assert.match(plain(row('U05')), /it conflicts with its base/);
  assert.doesNotMatch(plain(row('U05')), READY);
  assert.match(plain(row('U06')), READY);
  assert.match(plain(row('U06')), /forge note/);
});

test('U04-AC-4 a running node and a merged node show neither "ready to merge" nor "still being worked on"', async () => {
  const row = await render([node('U07', 'running', { started: 1700000000 }), node('U08', 'merged', { pr: 41 }),
    node('U09', 'ready'), node('U10', 'question', { text: 'which?' }), node('U11', 'waiting')]);
  for (const id of ['U07', 'U08', 'U09', 'U10', 'U11']) {
    assert.doesNotMatch(plain(row(id)), READY, `${id}: not ready to merge`);
    assert.doesNotMatch(plain(row(id)), WORKED, `${id}: not still being worked on`);
  }
});

test('U04-AC-4 a node that is not pr-open shows neither text even when its merge fields are set', async () => {
  const row = await render([node('U12', 'running', { merge_ready: true, merge_why: 'stray note' }),
    node('U13', 'merged', { merge_ready: false, merge_why: 'stray reason' })]);
  for (const id of ['U12', 'U13']) {
    assert.doesNotMatch(plain(row(id)), READY, `${id}: not ready to merge`);
    assert.doesNotMatch(plain(row(id)), WORKED, `${id}: not still being worked on`);
  }
});
