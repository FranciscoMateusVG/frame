import assert from 'node:assert/strict';
import { once } from 'node:events';
import { test } from 'node:test';
import { startTrialAdmin, TrialControl } from './trial-control.js';

test('real loopback HTTP fences reset, activation and in-flight teardown', async () => {
  // Pure lifecycle seed; intentionally not a v2 fixture or batch scenario.
  const control = new TrialControl(() => ({ state: { count: 0 }, seed_sha256: 'a'.repeat(64) }));
  const server = startTrialAdmin(control, 0);
  await once(server, 'listening');
  const addr = server.address();
  assert.ok(addr && typeof addr === 'object');
  assert.equal(addr.address, '127.0.0.1');
  const origin = `http://127.0.0.1:${addr.port}`;
  const request = async (path: string, value?: unknown, headers = {}) => {
    const r = await fetch(origin + path, {
      method: value === undefined ? 'GET' : 'POST',
      headers: { 'Content-Type': 'application/json', ...headers },
      ...(value === undefined ? {} : { body: JSON.stringify(value) }),
    });
    return { status: r.status, data: (await r.json()) as Record<string, unknown> };
  };
  try {
    let stamp = { boot_id: control.boot_id, generation: 0, trial_id: 'test-1' };
    assert.equal((await request('/unknown')).status, 404);
    assert.equal((await request('/reset')).status, 405);
    assert.equal((await request('/status', undefined, { Origin: origin })).status, 403);
    assert.equal((await request('/reset', { padding: 'x'.repeat(5000) })).status, 413);
    assert.equal((await request('/reset', [], { 'Content-Type': 'text/plain' })).status, 415);

    assert.equal(
      (await request('/reset', { ...stamp, scenario: 'lifecycle' }, { Origin: origin })).status,
      403,
    );
    assert.equal(
      (await request('/reset', { ...stamp, scenario: 'lifecycle', extra: true })).status,
      400,
    );
    assert.equal(
      (await request('/reset', { ...stamp, boot_id: 'old-boot', scenario: 'lifecycle' })).status,
      409,
    );
    assert.equal((await request('/reset', { ...stamp, scenario: 'lifecycle' })).status, 200);
    stamp = { ...stamp, generation: 1 };
    assert.equal((await request('/reset', { ...stamp, scenario: 'lifecycle' })).status, 409);
    assert.equal((await request('/start', stamp)).status, 200);
    assert.equal((await request('/reset', { ...stamp, scenario: 'lifecycle' })).status, 409);
    let release: () => void = () => {};
    const pending = control.command(async (state) => {
      await new Promise<void>((resolve) => {
        release = resolve;
      });
      state.count += 1;
    });
    assert.equal((await request('/finish', stamp)).status, 409);
    release();
    await pending;
    assert.equal(control.current().count, 1);
    assert.equal((await request('/finish', stamp)).status, 200);
    assert.equal(
      (await request('/reset', { ...stamp, trial_id: 'test-2', scenario: 'lifecycle' })).status,
      200,
    );
    assert.equal(control.current().count, 0);
    assert.equal((await request('/start', stamp)).status, 409);
    assert.equal(
      (await request('/abort', { ...stamp, generation: 2, trial_id: 'test-2' })).status,
      200,
    );
    assert.equal(control.status().phase, 'aborted');
    await assert.rejects(control.command(async () => {}));
    assert.equal(new TrialControl().status().configured, false);
    assert.notEqual(new TrialControl().boot_id, control.boot_id);
  } finally {
    server.close();
    server.closeAllConnections();
    await once(server, 'close');
  }
});
