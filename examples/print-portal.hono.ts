/**
 * Example: the print-shop portal end to end, in one process.
 *
 * Boots a fake Incluir service API (real HTTP server backed by the
 * in-memory fake), wires the portal exactly like src/http/server.ts but
 * with the HTTP adapter pointed at that fake, and walks the supplier
 * journey through the portal's JSON API: login → list → download →
 * collected → quote → (staff approves) → printed → logout.
 *
 * Usage: pnpm tsx examples/print-portal.hono.ts
 */
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import type { AddressInfo } from 'node:net';
import { serve } from '@hono/node-server';
import { LoginThrottleMemory } from '../src/adapters/login-throttle.memory.js';
import { PrintApiHttp } from '../src/adapters/print-api.http.js';
import { SessionStoreMemory } from '../src/adapters/session-store.memory.js';
import { DEFAULT_SESSION_POLICY } from '../src/domain/portal-session.js';
import { createPortalApp } from '../src/http/portal-app.js';
import { ConsoleLogger } from '../src/observability/console-logger.js';
import { noopTracer } from '../src/observability/tracer.js';
import { startFakeUpstream } from '../tests/helpers/fake-print-upstream.js';
import { PDF_BYTES, seedTwoFileOrder } from '../tests/helpers/print-fixtures.js';

console.log('🖨️  Frame Example: print-shop portal (Hono BFF → service API)');
console.log('============================================================');

const upstream = await startFakeUpstream();
const order = seedTwoFileOrder(upstream.api);
const password = randomBytes(18).toString('base64url');
const observability = { logger: new ConsoleLogger(), tracer: noopTracer() };

const app = createPortalApp({
  print: {
    printApi: new PrintApiHttp({ origin: upstream.origin, token: upstream.token }),
    observability,
  },
  session: {
    sessions: new SessionStoreMemory(),
    throttle: new LoginThrottleMemory(),
    policy: DEFAULT_SESSION_POLICY,
    clock: () => new Date(),
    randomToken: () => randomBytes(32).toString('base64url'),
    password,
    observability,
  },
  portalOrigin: 'https://grafica.example',
  trustedProxies: [],
  logger: observability.logger,
  requestId: randomUUID,
});
const server = serve({ fetch: app.fetch, port: 0, hostname: '127.0.0.1' });
if (!server.listening) await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

const cookies = new Map<string, string>();
async function call(path: string, init: RequestInit & { csrf?: string } = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set('Cookie', [...cookies].map(([k, v]) => `${k}=${v}`).join('; '));
  if (init.method && init.method !== 'GET') headers.set('Origin', 'https://grafica.example');
  if (init.csrf) headers.set('X-CSRF-Token', init.csrf);
  const res = await fetch(`${base}${path}`, { ...init, headers });
  for (const raw of res.headers.getSetCookie()) {
    const [pair = ''] = raw.split(';');
    const [name = '', value = ''] = pair.split('=');
    if (value) cookies.set(name, value);
    else cookies.delete(name);
  }
  return res;
}
const json = (body: unknown) => ({
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});
function expectStatus(res: Response, status: number, label: string) {
  if (res.status !== status) throw new Error(`${label}: expected ${status}, got ${res.status}`);
  console.log(`✅ ${label} → ${res.status}`);
}

try {
  let { csrfToken } = (await (await call('/api/session')).json()) as { csrfToken: string };
  const login = await call('/api/session', {
    method: 'POST',
    csrf: csrfToken,
    ...json({ password }),
  });
  expectStatus(login, 200, 'POST /api/session (login)');
  ({ csrfToken } = (await login.json()) as { csrfToken: string });

  const list = await call('/api/print/v1/orders');
  expectStatus(list, 200, 'GET /api/print/v1/orders');

  const detail = await call(`/api/print/v1/orders/${order.id}`);
  expectStatus(detail, 200, `GET order ${order.reference}`);
  const file = await call(`/api/print/v1/orders/${order.id}/files/${order.jobs[0]?.file.id}`);
  const digest = createHash('sha256')
    .update(Buffer.from(await file.arrayBuffer()))
    .digest('hex');
  expectStatus(
    file,
    200,
    `download file (sha256 ${digest === order.jobs[0]?.file.sha256 ? 'matches' : 'MISMATCH'})`,
  );

  const collected = await call(`/api/print/v1/orders/${order.id}/collected`, {
    method: 'POST',
    csrf: csrfToken,
    ...json({ revision: 1 }),
    headers: {
      'Content-Type': 'application/json',
      'If-Match': detail.headers.get('etag') ?? '',
      'Idempotency-Key': randomUUID(),
    },
  });
  expectStatus(collected, 200, 'POST collected');

  const form = new FormData();
  form.append('file', new File([PDF_BYTES], 'orcamento.pdf'));
  form.append('amountCents', '45900');
  form.append('orderRevision', '1');
  const quoted = await call(`/api/print/v1/orders/${order.id}/quotes`, {
    method: 'POST',
    csrf: csrfToken,
    body: form,
    headers: { 'If-Match': collected.headers.get('etag') ?? '', 'Idempotency-Key': randomUUID() },
  });
  expectStatus(quoted, 201, 'POST quotes (R$ 459,00)');
  const quoteId = ((await quoted.json()) as { order: { currentQuote: { id: string } } }).order
    .currentQuote.id;

  upstream.api.approveQuote(order.id);
  console.log('✅ Financeiro approves the quote (staff side, outside the portal)');
  const approved = await call(`/api/print/v1/orders/${order.id}`);
  const printed = await call(`/api/print/v1/orders/${order.id}/printed`, {
    method: 'POST',
    csrf: csrfToken,
    body: JSON.stringify({ revision: 1, quoteId }),
    headers: {
      'Content-Type': 'application/json',
      'If-Match': approved.headers.get('etag') ?? '',
      'Idempotency-Key': randomUUID(),
    },
  });
  expectStatus(printed, 200, 'POST printed');

  expectStatus(
    await call('/api/session', { method: 'DELETE', csrf: csrfToken }),
    204,
    'DELETE /api/session (logout)',
  );
  expectStatus(await call('/api/print/v1/orders'), 401, 'GET orders after logout');
  console.log('\n🎉 Example completed successfully!');
} finally {
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await upstream.close();
}
