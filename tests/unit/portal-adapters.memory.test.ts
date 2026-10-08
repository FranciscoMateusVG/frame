import { describe, expect, it } from 'vitest';
import { LoginThrottleMemory } from '../../src/adapters/login-throttle.memory.js';
import { SessionStoreMemory } from '../../src/adapters/session-store.memory.js';
import type { PortalSession } from '../../src/domain/portal-session.js';

const t0 = new Date('2026-10-08T00:00:00Z');
const at = (ms: number) => new Date(t0.getTime() + ms);
const session = (id: string, authenticated: boolean): PortalSession => ({
  id,
  csrfToken: `csrf-${id}`,
  authenticated,
  createdAt: t0,
  lastSeenAt: t0,
});

describe('SessionStoreMemory', () => {
  it('stores, touches, deletes and sweeps', async () => {
    const store = new SessionStoreMemory();
    await store.put(session('a', true));
    await store.touch('a', at(1000));
    expect((await store.get('a'))?.lastSeenAt).toEqual(at(1000));
    await store.touch('missing', at(1));
    expect(await store.delete('a')).toBe(true);
    expect(await store.delete('a')).toBe(false);

    await store.put(session('b', false));
    await store.put(session('c', true));
    expect(await store.sweep((s) => !s.authenticated)).toBe(1);
    expect(store.size).toBe(1);
  });

  it('caps pre-sessions separately so a flood cannot evict logged-in sessions', async () => {
    const store = new SessionStoreMemory({ maxPreSessions: 3, maxSessions: 2 });
    await store.put(session('auth-1', true));
    for (let i = 0; i < 100; i++) await store.put(session(`pre-${i}`, false));
    expect(await store.get('auth-1')).toBeDefined();
    expect(await store.get('pre-0')).toBeUndefined();
    expect(await store.get('pre-99')).toBeDefined();
    expect(store.size).toBe(4);

    await store.put(session('auth-2', true));
    await store.touch('auth-1', at(5));
    await store.put(session('auth-3', true));
    // auth-2 was least recently active.
    expect(await store.get('auth-2')).toBeUndefined();
    expect(await store.get('auth-1')).toBeDefined();
  });
});

describe('LoginThrottleMemory', () => {
  it('blocks the 6th attempt per client until the oldest failure leaves the window', async () => {
    const throttle = new LoginThrottleMemory();
    for (let i = 0; i < 5; i++) {
      expect((await throttle.check('ip', at(i * 1000))).allowed).toBe(true);
      await throttle.recordFailure('ip', at(i * 1000));
    }
    const blocked = await throttle.check('ip', at(5000));
    expect(blocked).toEqual({ allowed: false, retryAfterSeconds: 15 * 60 - 5 });
    expect((await throttle.check('other', at(5000))).allowed).toBe(true);
    expect((await throttle.check('ip', at(15 * 60 * 1000 + 1))).allowed).toBe(true);
  });

  it('enforces the per-instance ceiling across clients and bounds tracked clients', async () => {
    const throttle = new LoginThrottleMemory({
      perClient: 5,
      perInstance: 10,
      windowMs: 60_000,
      maxClients: 4,
    });
    for (let i = 0; i < 10; i++) await throttle.recordFailure(`ip-${i}`, at(i));
    expect((await throttle.check('fresh', at(20))).allowed).toBe(false);
    expect((await throttle.check('fresh', at(60_001))).allowed).toBe(true);
  });
});
