/**
 * PrintApiHttp across a real HTTP boundary: the shared conformance suite
 * against the fake upstream server, then the failure modes that must map
 * to UpstreamUnavailableError (→ 503 in the portal).
 */
import { randomUUID } from 'node:crypto';
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest';
import { PrintApiHttp } from '../../src/adapters/print-api.http.js';
import { UpstreamUnavailableError } from '../../src/errors/upstream-unavailable.error.js';
import { type FakeUpstream, startFakeUpstream } from '../helpers/fake-print-upstream.js';
import { createTestObservability } from '../helpers/observability.js';
import { describePrintApiConformance } from '../helpers/print-api.conformance.js';
import { seedTwoFileOrder } from '../helpers/print-fixtures.js';

const obs = createTestObservability();
const upstreams: FakeUpstream[] = [];
afterAll(async () => {
  await Promise.all(upstreams.map((u) => u.close()));
  await obs.shutdown();
});

async function fresh(options: { timeoutMs?: number } = {}) {
  const upstream = await startFakeUpstream();
  upstreams.push(upstream);
  const api = new PrintApiHttp({ origin: upstream.origin, token: upstream.token, ...options });
  return { upstream, api };
}

describePrintApiConformance('HTTP → fake upstream', {
  factory: async () => {
    const { upstream, api } = await fresh();
    return { api, staff: upstream.api };
  },
  getSpans: () => obs.getSpans(),
  resetSpans: () => obs.reset(),
  expectedServerAddress: () => /^127\.0\.0\.1:\d+$/,
});

describe('PrintApiHttp — failure modes map to UpstreamUnavailableError', () => {
  let upstream: FakeUpstream;
  let api: PrintApiHttp;

  beforeEach(async () => {
    ({ upstream, api } = await fresh({ timeoutMs: 300 }));
  });
  afterEach(() => {
    Object.assign(upstream.behaviour, {
      delayMs: 0,
      failWith: 0,
      redirectTo: undefined,
      leakField: false,
    });
  });

  const unavailable = async (promise: Promise<unknown>) => {
    await expect(promise).rejects.toBeInstanceOf(UpstreamUnavailableError);
  };

  it('timeout', async () => {
    upstream.behaviour.delayMs = 1_000;
    await unavailable(api.listOrders({ limit: 1 }));
  });

  it('5xx with a non-contract body', async () => {
    upstream.behaviour.failWith = 502;
    await unavailable(api.listOrders({ limit: 1 }));
  });

  it('503 NOT_CONFIGURED-style answer', async () => {
    upstream.behaviour.failWith = 503;
    await unavailable(api.getMonthlyClose('2026-01'));
  });

  it('redirects are never followed (the bearer stays home)', async () => {
    const trap = await startFakeUpstream();
    upstreams.push(trap);
    upstream.behaviour.redirectTo = `${trap.origin}/api/print-portal/v1/orders`;
    await unavailable(api.listOrders({ limit: 1 }));
    expect(trap.seenHeaders).toHaveLength(0);
  });

  it('a body with a field outside the frozen contract', async () => {
    seedTwoFileOrder(upstream.api);
    upstream.behaviour.leakField = true;
    await unavailable(api.listOrders({ limit: 1 }));
  });

  it('a refused service token (401) is unavailability, not a login problem', async () => {
    const wrong = new PrintApiHttp({ origin: upstream.origin, token: `x${upstream.token}` });
    await unavailable(wrong.listOrders({ limit: 1 }));
  });

  it('connection refused', async () => {
    const dead = await startFakeUpstream();
    await dead.close();
    const api2 = new PrintApiHttp({ origin: dead.origin, token: dead.token });
    await unavailable(api2.listOrders({ limit: 1 }));
  });

  it('sends only the bearer and contract headers upstream', async () => {
    const order = seedTwoFileOrder(upstream.api);
    const { etag } = await api.getOrder(order.id);
    await api.markCollected(
      order.id,
      { revision: 1 },
      { ifMatch: etag, idempotencyKey: randomUUID() },
    );
    const last = upstream.seenHeaders.at(-1);
    expect(last?.get('authorization')).toBe(`Bearer ${upstream.token}`);
    expect(last?.get('cookie')).toBeNull();
    expect(last?.get('if-match')).toBe(etag);
  });
});
