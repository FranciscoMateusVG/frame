// TTP-only container entrypoint. Reuses the real HTTP test adapter, never Hono.
// The shared service is deliberately read-only so one trial cannot alter another.
import { createHash } from 'node:crypto';
import { createServer, request } from 'node:http';
import { PrintApiMemory } from '../../src/adapters/print-api.memory.js';
import { UpstreamRejectedError } from '../../src/errors/upstream-rejected.error.js';
import { startFakeUpstream } from '../../tests/helpers/fake-print-upstream.js';
import fixtures from '../../tests/helpers/print-portal-v1.fixture.json';

const token = process.env.INCLUIR_PRINT_SERVICE_TOKEN;
if (!token || token.length < 32) throw new Error('Synthetic upstream token required');
const fixtureHash = createHash('sha256').update(JSON.stringify(fixtures)).digest('hex');
const page = fixtures['GET /orders'];
const order = fixtures['GET /orders/:id (ready)'].order;
if (page.items.length !== 1 || page.items[0]?.id !== order.id || order.jobs.length !== 2)
  throw new Error('Frozen synthetic fixture changed');

// The benchmark used this same frozen read projection over the real HTTP helper.
class FrozenReadApi extends PrintApiMemory {
  override async listOrders(query: Parameters<PrintApiMemory['listOrders']>[0]) {
    if (query.cursor)
      throw new UpstreamRejectedError(400, 'INVALID_CURSOR', 'Synthetic fixture', 'ttp');
    return structuredClone(
      query.status && query.status !== order.status ? { items: [], nextCursor: null } : page,
    ) as Awaited<ReturnType<PrintApiMemory['listOrders']>>;
  }

  override async getOrder(id: string) {
    if (id !== order.id)
      throw new UpstreamRejectedError(404, 'NOT_FOUND', 'Synthetic fixture', 'ttp');
    return {
      value: structuredClone(order),
      etag: `"${order.id}:${order.version}"`,
    } as Awaited<ReturnType<PrintApiMemory['getOrder']>>;
  }
}

const upstream = await startFakeUpstream({ token, api: new FrozenReadApi() });
upstream.behaviour.delayMs = 0;
// Production-like staging has no reason to retain authorization headers at all.
upstream.seenHeaders.push = () => 0;
const target = new URL(upstream.origin);
const server = createServer((incoming, outgoing) => {
  outgoing.setHeader('Cache-Control', 'no-store');
  outgoing.setHeader('X-TTP-Fixture-SHA256', fixtureHash);
  if (incoming.method === 'GET' && incoming.url === '/healthz') {
    outgoing.setHeader('Content-Type', 'application/json');
    outgoing.end(JSON.stringify({ status: 'ok', fixtureHash, orders: 1, delayMs: 0 }));
    return;
  }
  if (incoming.method !== 'GET') {
    outgoing.writeHead(405, { Allow: 'GET' });
    outgoing.end();
    return;
  }
  // Fixed destination: an absolute request target cannot turn this into a proxy.
  const hop = request(
    {
      hostname: target.hostname,
      port: target.port,
      method: 'GET',
      path: incoming.url,
      headers: { authorization: incoming.headers.authorization ?? '' },
      timeout: 15_000,
    },
    (response) => {
      outgoing.writeHead(response.statusCode ?? 502, response.headers);
      response.pipe(outgoing);
    },
  );
  hop.on('timeout', () => hop.destroy());
  hop.on('error', () => {
    if (!outgoing.headersSent) outgoing.writeHead(502);
    outgoing.end();
  });
  outgoing.on('close', () => hop.destroy());
  hop.end();
});

server.listen(4001, '0.0.0.0', () => {
  console.log(JSON.stringify({ event: 'ttp_fake_ready', port: 4001, fixtureHash, delayMs: 0 }));
});
for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.once(signal, () => {
    console.log(JSON.stringify({ event: 'ttp_fake_stopping' }));
    server.close(() => void upstream.close().then(() => process.exit(0)));
    server.closeIdleConnections();
  });
}
