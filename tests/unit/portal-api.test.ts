/**
 * Portal JSON API (spec §4.5, §5) through the real Hono app over the
 * in-memory upstream fake: sessions, cookies, CSRF/Origin, throttling,
 * the ten /api/print/v1 routes, error mapping and downloads.
 */
import { createHash, randomUUID } from 'node:crypto';
import { beforeEach, describe, expect, it } from 'vitest';
import type { PrintApi } from '../../src/adapters/print-api.js';
import { UpstreamUnavailableError } from '../../src/errors/upstream-unavailable.error.js';
import {
  createHarness,
  type Harness,
  PASSWORD,
  type PortalClient,
} from '../helpers/portal-harness.js';
import { PDF_BYTES, PNG_BYTES, seedTwoFileOrder } from '../helpers/print-fixtures.js';

const sha = (bytes: ArrayBuffer | Uint8Array) =>
  createHash('sha256')
    .update(Buffer.from(bytes as ArrayBuffer))
    .digest('hex');

function errorCode(body: unknown): string | undefined {
  return (body as { error?: { code?: string } }).error?.code;
}

describe('portal API — session', () => {
  let h: Harness;
  let browser: PortalClient;
  beforeEach(() => {
    h = createHarness();
    browser = h.client({ ip: '203.0.113.7' });
  });

  it('GET /api/session opens a host-only pre-session with a CSRF token', async () => {
    const res = await browser.get('/api/session');
    expect(res.status).toBe(200);
    expect(res.headers.get('cache-control')).toBe('no-store');
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toMatchObject({ authenticated: false, expiresAt: null });
    expect(String(body.csrfToken)).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const cookie = browser.setCookies.find((c) => c.startsWith('__Host-print_presession='));
    expect(cookie).toMatch(/; Path=\/; Secure; HttpOnly; SameSite=Lax$/);
    expect(cookie).not.toMatch(/Domain/i);

    // Same pre-session on the next GET (no new cookie).
    const again = (await (await browser.get('/api/session')).json()) as Record<string, unknown>;
    expect(again.csrfToken).toBe(body.csrfToken);
    expect(browser.setCookies).toHaveLength(1);
  });

  it('login rotates to a new session cookie and CSRF token; the pre-session is not promoted', async () => {
    const pre = await browser.get('/api/session');
    const preCsrf = ((await pre.json()) as { csrfToken: string }).csrfToken;
    const preId = browser.cookies.get('__Host-print_presession');

    browser.csrf = preCsrf;
    const res = await browser.post('/api/session', { password: PASSWORD });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      authenticated: boolean;
      csrfToken: string;
      expiresAt: string;
    };
    expect(body.authenticated).toBe(true);
    expect(body.csrfToken).not.toBe(preCsrf);
    expect(new Date(body.expiresAt).getTime()).toBe(h.clock.now.getTime() + 30 * 60 * 1000);
    expect(JSON.stringify(body)).not.toContain(PASSWORD);

    const sessionId = browser.cookies.get('__Host-print_session');
    expect(sessionId).toBeDefined();
    expect(sessionId).not.toBe(preId);
    expect(browser.cookies.has('__Host-print_presession')).toBe(false);
    expect(await h.sessions.get(preId ?? '')).toBeUndefined();

    const state = (await (await browser.get('/api/session')).json()) as Record<string, unknown>;
    expect(state).toMatchObject({ authenticated: true, csrfToken: body.csrfToken });
  });

  it('login refuses missing/foreign Origin and missing/wrong CSRF with 403 CSRF_FAILED', async () => {
    await browser.get('/api/session');
    for (const origin of [null, 'https://evil.test', 'https://grafica.test.evil.test']) {
      const res = await browser.request('POST', '/api/session', {
        json: { password: PASSWORD },
        origin,
      });
      expect(res.status).toBe(403);
      expect(errorCode(await res.json())).toBe('CSRF_FAILED');
    }
    browser.csrf = undefined;
    expect((await browser.post('/api/session', { password: PASSWORD })).status).toBe(403);
    browser.csrf = 'x'.repeat(43);
    expect((await browser.post('/api/session', { password: PASSWORD })).status).toBe(403);

    // No pre-session cookie at all.
    const stranger = h.client();
    stranger.csrf = 'x'.repeat(43);
    expect((await stranger.post('/api/session', { password: PASSWORD })).status).toBe(403);
  });

  it('wrong password is 401 INVALID_CREDENTIALS; malformed body is 400', async () => {
    const res = await browser.login('wrong password, quite long');
    expect(res.status).toBe(401);
    expect(errorCode(await res.json())).toBe('INVALID_CREDENTIALS');
    for (const body of [
      {},
      { password: 1 },
      { password: PASSWORD, extra: true },
      'x',
      [PASSWORD],
    ]) {
      const r = await browser.post('/api/session', body);
      expect(r.status).toBe(400);
      expect(errorCode(await r.json())).toBe('INVALID_REQUEST');
    }
    const truncated = await browser.request('POST', '/api/session', {
      body: '{"password":"abc',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': browser.csrf ?? '' },
    });
    expect(truncated.status).toBe(400);
  });

  it('5 wrong passwords then 429 + Retry-After, even for the right password; XFF does not bypass', async () => {
    await browser.get('/api/session');
    browser.csrf = (
      (await (await browser.get('/api/session')).json()) as { csrfToken: string }
    ).csrfToken;
    for (let i = 0; i < 5; i++) {
      expect(
        (await browser.post('/api/session', { password: `wrong-${i}-xxxxxxxxxxxx` })).status,
      ).toBe(401);
    }
    const sixth = await browser.post('/api/session', { password: 'wrong-6-xxxxxxxxxxxx' });
    expect(sixth.status).toBe(429);
    expect(errorCode(await sixth.json())).toBe('RATE_LIMITED');
    expect(Number(sixth.headers.get('retry-after'))).toBeGreaterThan(0);

    expect((await browser.post('/api/session', { password: PASSWORD })).status).toBe(429);
    const spoofed = await browser.post(
      '/api/session',
      { password: PASSWORD },
      { 'X-Forwarded-For': '198.51.100.99' },
    );
    expect(spoofed.status).toBe(429);

    // Another client is unaffected; after the window the first one may retry.
    expect((await h.client({ ip: '203.0.113.8' }).login()).status).toBe(200);
    h.clock.now = new Date(h.clock.now.getTime() + 15 * 60 * 1000 + 1000);
    expect((await browser.post('/api/session', { password: PASSWORD })).status).toBe(200);
  });

  it('trusted proxy: XFF is honoured only from the configured proxy address', async () => {
    const proxied = createHarness({ trustedProxies: ['10.0.0.1'] });
    const viaProxy = proxied.client({ ip: '10.0.0.1' });
    await viaProxy.get('/api/session');
    viaProxy.csrf = (
      (await (await viaProxy.get('/api/session')).json()) as { csrfToken: string }
    ).csrfToken;
    for (let i = 0; i < 5; i++) {
      await viaProxy.post(
        '/api/session',
        { password: `nope-${i}-xxxxxxxxxxxxx` },
        { 'X-Forwarded-For': '198.51.100.1' },
      );
    }
    const blocked = await viaProxy.post(
      '/api/session',
      { password: PASSWORD },
      { 'X-Forwarded-For': '198.51.100.1' },
    );
    expect(blocked.status).toBe(429);
    const other = await viaProxy.post(
      '/api/session',
      { password: PASSWORD },
      { 'X-Forwarded-For': '198.51.100.2' },
    );
    expect(other.status).toBe(200);
  });

  it('logout revokes immediately; repeating it without a session is a silent 204', async () => {
    await browser.login();
    const sessionId = browser.cookies.get('__Host-print_session') ?? '';
    expect((await browser.get('/api/print/v1/orders')).status).toBe(200);

    const noOrigin = await browser.request('DELETE', '/api/session', {
      origin: null,
      headers: { 'X-CSRF-Token': browser.csrf ?? '' },
    });
    expect(noOrigin.status).toBe(403);
    const badCsrf = await browser.request('DELETE', '/api/session', {
      headers: { 'X-CSRF-Token': 'nope' },
    });
    expect(badCsrf.status).toBe(403);

    const out = await browser.request('DELETE', '/api/session', {
      headers: { 'X-CSRF-Token': browser.csrf ?? '' },
    });
    expect(out.status).toBe(204);
    expect(await h.sessions.get(sessionId)).toBeUndefined();

    // The old cookie value no longer works, even if a client kept it.
    const replayer = h.client();
    replayer.cookies.set('__Host-print_session', sessionId);
    const after = await replayer.get('/api/print/v1/orders');
    expect(after.status).toBe(401);
    expect(errorCode(await after.json())).toBe('UNAUTHENTICATED');

    const again = await h
      .client()
      .request('DELETE', '/api/session', { headers: { 'X-CSRF-Token': 'x' } });
    expect(again.status).toBe(204);
  });

  it('idle (30 min) and absolute (8 h) expiry end the session', async () => {
    await browser.login();
    h.clock.now = new Date(h.clock.now.getTime() + 29 * 60 * 1000);
    expect((await browser.get('/api/print/v1/orders')).status).toBe(200);
    h.clock.now = new Date(h.clock.now.getTime() + 30 * 60 * 1000 + 1);
    expect((await browser.get('/api/print/v1/orders')).status).toBe(401);

    const busy = h.client({ ip: '203.0.113.9' });
    await busy.login();
    for (let elapsed = 0; elapsed < 8 * 60; elapsed += 20) {
      h.clock.now = new Date(h.clock.now.getTime() + 20 * 60 * 1000);
      const res = await busy.get('/api/print/v1/orders');
      expect(res.status).toBe(elapsed + 20 < 8 * 60 ? 200 : 401);
    }
  });
});

describe('portal API — /api/print/v1', () => {
  let h: Harness;
  let browser: PortalClient;
  beforeEach(async () => {
    h = createHarness();
    browser = h.client();
    await browser.login();
  });

  it('every route requires a session (JSON 401, never a redirect)', async () => {
    const anon = h.client();
    const id = randomUUID();
    for (const [method, path] of [
      ['GET', '/api/print/v1/orders'],
      ['GET', `/api/print/v1/orders/${id}`],
      ['GET', `/api/print/v1/orders/${id}/files/${id}`],
      ['POST', `/api/print/v1/orders/${id}/collected`],
      ['POST', `/api/print/v1/orders/${id}/quotes`],
      ['GET', `/api/print/v1/orders/${id}/quotes/${id}/file`],
      ['POST', `/api/print/v1/orders/${id}/printed`],
      ['GET', '/api/print/v1/monthly-closes/2026-09'],
      ['POST', '/api/print/v1/monthly-closes/2026-09/invoice'],
      ['GET', '/api/print/v1/monthly-closes/2026-09/invoice'],
    ] as const) {
      const res = await anon.request(method, path);
      expect(res.status, `${method} ${path}`).toBe(401);
      expect(errorCode(await res.json())).toBe('UNAUTHENTICATED');
    }
  });

  it('refuses a browser Authorization header instead of forwarding it', async () => {
    const res = await browser.get('/api/print/v1/orders', {
      headers: { Authorization: 'Bearer stolen' },
    });
    expect(res.status).toBe(400);
  });

  it('lists, filters and paginates; validates the query', async () => {
    const orders = [seedTwoFileOrder(h.api), seedTwoFileOrder(h.api), seedTwoFileOrder(h.api)];
    const page1 = await browser.get('/api/print/v1/orders?limit=2');
    expect(page1.status).toBe(200);
    const body1 = (await page1.json()) as { items: { id: string }[]; nextCursor: string };
    expect(body1.items.map((o) => o.id)).toEqual([orders[0]?.id, orders[1]?.id]);
    const page2 = (await (
      await browser.get(
        `/api/print/v1/orders?limit=2&cursor=${encodeURIComponent(body1.nextCursor)}`,
      )
    ).json()) as { items: { id: string }[]; nextCursor: null };
    expect(page2).toEqual({
      items: [expect.objectContaining({ id: orders[2]?.id })],
      nextCursor: null,
    });

    for (const q of ['limit=0', 'limit=101', 'limit=abc', 'status=bogus']) {
      const res = await browser.get(`/api/print/v1/orders?${q}`);
      expect(res.status, q).toBe(400);
    }
    const badCursor = await browser.get('/api/print/v1/orders?cursor=garbage');
    expect(badCursor.status).toBe(400);
    expect(errorCode(await badCursor.json())).toBe('INVALID_CURSOR');
  });

  it('GET order relays ETag; downloads stream exact bytes as attachments', async () => {
    const order = seedTwoFileOrder(h.api);
    const res = await browser.get(`/api/print/v1/orders/${order.id}`);
    expect(res.headers.get('etag')).toBe(`"${order.id}:1"`);
    const { order: dto } = (await res.json()) as { order: typeof order };
    expect(dto.jobs.map((j) => [j.title, j.copies])).toEqual([
      ['Apostila de Matemática', 2],
      ['Lista de Física', 7],
    ]);

    const physics = dto.jobs[1];
    const file = await browser.get(`/api/print/v1/orders/${order.id}/files/${physics?.file.id}`);
    expect(file.status).toBe(200);
    expect(file.headers.get('content-type')).toBe('image/png');
    expect(file.headers.get('content-length')).toBe(String(PNG_BYTES.byteLength));
    expect(file.headers.get('content-disposition')).toBe(
      `attachment; filename="f_sica final.png"; filename*=UTF-8''f%C3%ADsica%20final.png`,
    );
    expect(file.headers.get('x-content-type-options')).toBe('nosniff');
    expect(file.headers.get('cache-control')).toBe('private, no-store');
    expect(sha(await file.arrayBuffer())).toBe(physics?.file.sha256);

    const missing = await browser.get(`/api/print/v1/orders/${order.id}/files/${randomUUID()}`);
    expect(missing.status).toBe(404);
    expect(errorCode(await missing.json())).toBe('NOT_FOUND');
  });

  it('commands need CSRF + Origin; relay If-Match/Idempotency-Key and replay', async () => {
    const order = seedTwoFileOrder(h.api);
    const etag = `"${order.id}:1"`;
    const path = `/api/print/v1/orders/${order.id}/collected`;
    const key = randomUUID();

    const noCsrf = await browser.request('POST', path, {
      json: { revision: 1 },
      headers: { 'If-Match': etag, 'Idempotency-Key': key },
    });
    expect(noCsrf.status).toBe(403);
    expect(errorCode(await noCsrf.json())).toBe('CSRF_FAILED');
    const noOrigin = await browser.request('POST', path, {
      json: { revision: 1 },
      origin: null,
      headers: { 'X-CSRF-Token': browser.csrf ?? '', 'If-Match': etag, 'Idempotency-Key': key },
    });
    expect(noOrigin.status).toBe(403);

    const missing = await browser.post(path, { revision: 1 });
    expect(missing.status).toBe(428);
    expect(errorCode(await missing.json())).toBe('PRECONDITION_REQUIRED');

    for (const body of [{}, { revision: '1' }, { revision: 1, extra: 1 }, [1]]) {
      expect(
        (await browser.post(path, body, { 'If-Match': etag, 'Idempotency-Key': key })).status,
      ).toBe(400);
    }

    const ok = await browser.post(
      path,
      { revision: 1 },
      { 'If-Match': etag, 'Idempotency-Key': key },
    );
    expect(ok.status).toBe(200);
    expect(ok.headers.get('etag')).toBe(`"${order.id}:2"`);
    expect(ok.headers.get('idempotency-replayed')).toBeNull();
    const replay = await browser.post(
      path,
      { revision: 1 },
      { 'If-Match': etag, 'Idempotency-Key': key },
    );
    expect(replay.status).toBe(200);
    expect(replay.headers.get('idempotency-replayed')).toBe('true');
    expect(await replay.json()).toEqual(await ok.json());

    const stale = await browser.post(
      path,
      { revision: 1 },
      { 'If-Match': etag, 'Idempotency-Key': randomUUID() },
    );
    expect(stale.status).toBe(412);
    expect(errorCode(await stale.json())).toBe('VERSION_MISMATCH');
  });

  it('quote upload: multipart validation, 413 cap, 201 + quote download; printed after approval', async () => {
    const order = seedTwoFileOrder(h.api);
    const collected = await browser.post(
      `/api/print/v1/orders/${order.id}/collected`,
      { revision: 1 },
      { 'If-Match': `"${order.id}:1"`, 'Idempotency-Key': randomUUID() },
    );
    const etag = collected.headers.get('etag') ?? '';
    const quotePath = `/api/print/v1/orders/${order.id}/quotes`;
    const send = (fields: Record<string, string | Blob>, headers: Record<string, string> = {}) => {
      const form = new FormData();
      for (const [k, v] of Object.entries(fields)) form.append(k, v);
      return browser.request('POST', quotePath, {
        body: form,
        headers: {
          'X-CSRF-Token': browser.csrf ?? '',
          'If-Match': etag,
          'Idempotency-Key': randomUUID(),
          ...headers,
        },
      });
    };
    const pdf = new File([PDF_BYTES], 'orçamento.pdf', { type: 'application/pdf' });

    expect((await send({ amountCents: '100', orderRevision: '1' })).status).toBe(400);
    expect((await send({ file: pdf, amountCents: '1,00', orderRevision: '1' })).status).toBe(400);
    expect((await send({ file: pdf, amountCents: '0', orderRevision: '1' })).status).toBe(400);
    expect(
      (await send({ file: pdf, amountCents: '100', orderRevision: '1', extra: 'x' })).status,
    ).toBe(400);
    const repeated = new FormData();
    repeated.append('file', pdf);
    repeated.append('amountCents', '100');
    repeated.append('amountCents', '200');
    repeated.append('orderRevision', '1');
    expect(
      (
        await browser.request('POST', quotePath, {
          body: repeated,
          headers: {
            'X-CSRF-Token': browser.csrf ?? '',
            'If-Match': etag,
            'Idempotency-Key': randomUUID(),
          },
        })
      ).status,
    ).toBe(400);
    expect(
      (await send({ file: new File([], 'empty.pdf'), amountCents: '100', orderRevision: '1' }))
        .status,
    ).toBe(400);

    const big = new File([new Uint8Array(5 * 1024 * 1024 + 1)], 'big.pdf');
    const tooBig = await send({ file: big, amountCents: '100', orderRevision: '1' });
    expect(tooBig.status).toBe(413);
    expect(errorCode(await tooBig.json())).toBe('FILE_TOO_LARGE');
    const huge = await send({
      file: new File([new Uint8Array(6 * 1024 * 1024)], 'huge.pdf'),
      amountCents: '1',
      orderRevision: '1',
    });
    expect(huge.status).toBe(413);

    const html = await send({
      file: new File(['<html>'], 'x.pdf'),
      amountCents: '100',
      orderRevision: '1',
    });
    expect(html.status).toBe(415);

    const created = await send({ file: pdf, amountCents: '45900', orderRevision: '1' });
    expect(created.status).toBe(201);
    const { order: quoted } = (await created.json()) as {
      order: { status: string; currentQuote: { id: string } };
    };
    expect(quoted.status).toBe('quote_pending');
    const doc = await browser.get(
      `/api/print/v1/orders/${order.id}/quotes/${quoted.currentQuote.id}/file`,
    );
    expect(sha(await doc.arrayBuffer())).toBe(sha(PDF_BYTES));

    h.api.approveQuote(order.id);
    const approved = await browser.get(`/api/print/v1/orders/${order.id}`);
    const printed = await browser.post(
      `/api/print/v1/orders/${order.id}/printed`,
      { revision: 1, quoteId: quoted.currentQuote.id },
      { 'If-Match': approved.headers.get('etag') ?? '', 'Idempotency-Key': randomUUID() },
    );
    expect(printed.status).toBe(200);
    expect(((await printed.json()) as { order: { status: string } }).order.status).toBe('printed');
  });

  it('monthly closes: competence validation, virtual close, invoice submit and download', async () => {
    const bad = await browser.get('/api/print/v1/monthly-closes/2026-13');
    expect(bad.status).toBe(400);
    expect(errorCode(await bad.json())).toBe('INVALID_COMPETENCE');

    // Print an order in September (clock), then read October.
    h.clock.now = new Date('2026-09-15T15:00:00.000Z');
    const order = seedTwoFileOrder(h.api);
    let etag = `"${order.id}:1"`;
    etag = (
      await h.api.markCollected(
        order.id,
        { revision: 1 },
        { ifMatch: etag, idempotencyKey: randomUUID() },
      )
    ).etag;
    const q = await h.api.submitQuote(
      order.id,
      { amountCents: 57_900, orderRevision: 1, file: { filename: 'q.pdf', bytes: PDF_BYTES } },
      { ifMatch: etag, idempotencyKey: randomUUID() },
    );
    const approved = h.api.approveQuote(order.id);
    await h.api.markPrinted(
      order.id,
      { revision: 1, quoteId: q.value.currentQuote?.id ?? '' },
      { ifMatch: `"${order.id}:${approved.version}"`, idempotencyKey: randomUUID() },
    );
    h.clock.now = new Date('2026-10-08T12:00:00.000Z');

    const closeRes = await browser.get('/api/print/v1/monthly-closes/2026-09');
    expect(closeRes.status).toBe(200);
    const { close } = (await closeRes.json()) as {
      close: { periodClosed: boolean; expectedTotalCents: number; items: unknown[] };
    };
    expect(close).toMatchObject({ periodClosed: true, expectedTotalCents: 57_900 });
    expect(close.items).toHaveLength(1);

    const form = new FormData();
    form.append('file', new File([PDF_BYTES], 'nf.pdf'));
    form.append('declaredTotalCents', '57900');
    const submitted = await browser.request(
      'POST',
      '/api/print/v1/monthly-closes/2026-09/invoice',
      {
        body: form,
        headers: {
          'X-CSRF-Token': browser.csrf ?? '',
          'If-Match': closeRes.headers.get('etag') ?? '',
          'Idempotency-Key': randomUUID(),
        },
      },
    );
    expect(submitted.status).toBe(201);
    expect(((await submitted.json()) as { close: { state: string } }).close.state).toBe(
      'submitted',
    );

    const nf = await browser.get('/api/print/v1/monthly-closes/2026-09/invoice');
    expect(nf.status).toBe(200);
    expect(sha(await nf.arrayBuffer())).toBe(sha(PDF_BYTES));
  });

  it('405 for unlisted methods on known routes, 404 elsewhere', async () => {
    const id = randomUUID();
    const del = await browser.request('DELETE', `/api/print/v1/orders/${id}`, {
      headers: { 'X-CSRF-Token': browser.csrf ?? '' },
    });
    expect(del.status).toBe(405);
    expect(errorCode(await del.json())).toBe('METHOD_NOT_ALLOWED');
    const nowhere = await browser.get('/api/print/v1/admin');
    expect(nowhere.status).toBe(404);
    expect((await browser.get('/api/print-portal/v1/orders')).status).toBe(404);
  });

  it('upstream unavailability is 503 UPSTREAM_UNAVAILABLE and keeps the session', async () => {
    const down: PrintApi = new Proxy({} as PrintApi, {
      get: () => async () => {
        throw new UpstreamUnavailableError('timeout');
      },
    });
    const hd = createHarness({ printApi: down });
    const b = hd.client();
    await b.login();
    const res = await b.get('/api/print/v1/orders');
    expect(res.status).toBe(503);
    expect(errorCode(await res.json())).toBe('UPSTREAM_UNAVAILABLE');
    expect((await (await b.get('/api/session')).json()) as object).toMatchObject({
      authenticated: true,
    });
  });
});
