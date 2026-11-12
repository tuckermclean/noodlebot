// W06-AC-6, the repository view's loop and STOP states: each is a data-badge element naming its state.
import test from 'node:test';
import assert from 'node:assert/strict';
import { parse, all, by } from './dom.mjs';
import { loadFixture } from './helper.mjs';
import { MIN } from './design-helper.mjs';

const clone = (x) => JSON.parse(JSON.stringify(x));
const repoFile = (data, name) => Object.values(data.files).find((f) => f && f.repo === name);

test('W06-AC-6 the repository view\'s STOP state (not set, requested) and loop state (idle, running) are data-badge elements naming them', async () => {
  const views = await import('../views.js');
  const fx = loadFixture();
  const data = { manifest: fx.manifest, files: fx.files };
  const ctx = { now: fx.manifest.seen * 1000 + MIN, lastSuccess: fx.manifest.seen * 1000 + MIN, repo: 'acme/alpha' };
  const render = (running, stop) => {
    const d = clone(data);
    repoFile(d, 'acme/alpha').running = running;
    repoFile(d, 'acme/alpha').stop = stop;
    return parse(views.renderRepo(d, ctx));
  };
  // STOP badges: data-badge value mentions STOP (as the existing requested pin) and the state ("not set" / "requested")
  const stopBadges = (root) => all(root, (e) => 'data-badge' in e.attrs && /stop/i.test(e.attrs['data-badge']));

  const unset = render(false, false);
  const u = stopBadges(unset);
  assert.ok(u.some((e) => /not set/i.test(e.attrs['data-badge']) && /not set/i.test(e.text)), 'STOP not set: a data-badge naming STOP and "not set", reading "not set"');
  assert.equal(by(unset, 'data-badge', 'idle').length >= 1, true, 'loop idle: data-badge="idle"');
  assert.ok(!u.some((e) => /requested/i.test(e.attrs['data-badge'])), 'STOP not set: no requested badge');

  const req = render(true, true);
  const q = stopBadges(req);
  assert.ok(q.some((e) => /requested/i.test(e.attrs['data-badge']) && /requested/i.test(e.text)), 'STOP requested: a data-badge naming STOP and "requested"');
  assert.ok(!q.some((e) => /not set/i.test(e.attrs['data-badge'])), 'STOP requested: no "not set" badge');
  assert.ok(by(req, 'data-badge', 'running').length >= 1, 'loop running: data-badge="running"');
});
