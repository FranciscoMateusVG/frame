/**
 * A real HTTP server speaking the Incluir service API
 * (`/api/print-portal/v1`) on an ephemeral port, backed by PrintApiMemory.
 *
 * Used to exercise PrintApiHttp and the whole portal across a real network
 * boundary (fetch, headers, multipart, streaming) without the Incluir
 * stack. The wire format follows PR B's routes/print-portal.ts: bearer
 * auth → 401 UNAUTHORIZED, `{error:{code,message,requestId}}`, ETag,
 * Idempotency-Replayed, attachment downloads, exact multipart fields.
 *
 * `behaviour` lets a test inject failures (latency, 5xx, redirects,
 * malformed bodies) to prove the portal's 503 mapping.
 */
import { randomUUID } from 'node:crypto';
import type { AddressInfo } from 'node:net';
import { serve } from '@hono/node-server';
import { type Context, Hono } from 'hono';
import { PrintApiMemory } from '../../src/adapters/print-api.memory.js';
import { UpstreamRejectedError } from '../../src/errors/upstream-rejected.error.js';

export interface FakeUpstreamBehaviour {
  /** Delay every response by this many ms. */
  delayMs?: number;
  /** Answer every request with this status and a non-contract body. */
  failWith?: number;
  /** Answer every request with a redirect to this URL. */
  redirectTo?: string;
  /** Add an unexpected field to every JSON body (contract violation). */
  leakField?: boolean;
  /** Answer every JSON request with a body of this many bytes. */
  hugeBodyBytes?: number;
  /** Answer every request with 429 RATE_LIMITED and this Retry-After (seconds). */
  rateLimitedFor?: number;
}

export interface FakeUpstream {
  readonly origin: string;
  readonly token: string;
  readonly api: PrintApiMemory;
  readonly behaviour: FakeUpstreamBehaviour;
  /** Authorization headers seen, newest last (to prove no browser data leaks upstream). */
  readonly seenHeaders: Headers[];
  close(): Promise<void>;
}

const methodNotAllowed = (c: Context) =>
  c.json(
    {
      error: {
        code: 'METHOD_NOT_ALLOWED',
        message: 'Método não permitido.',
        requestId: randomUUID(),
      },
    },
    405,
  );

export async function startFakeUpstream(
  options: { token?: string; api?: PrintApiMemory } = {},
): Promise<FakeUpstream> {
  const token =
    options.token ?? `svc_${randomUUID().replaceAll('-', '')}${randomUUID().replaceAll('-', '')}`;
  const api = options.api ?? new PrintApiMemory();
  const behaviour: FakeUpstreamBehaviour = {};
  const seenHeaders: Headers[] = [];
  const app = new Hono();

  const fail = (c: Context, error: unknown) => {
    if (error instanceof UpstreamRejectedError) {
      return c.json(
        { error: { code: error.code, message: error.upstreamMessage, requestId: error.requestId } },
        error.status as 400,
      );
    }
    throw error;
  };

  const json = (
    c: Context,
    body: Record<string, unknown>,
    status: number,
    headers: Record<string, string>,
  ) => {
    const payload = behaviour.leakField ? { ...body, bucket: 'solicitations' } : body;
    return c.json(payload, status as 200, { 'Cache-Control': 'no-store', ...headers });
  };

  const download = async (d: Awaited<ReturnType<PrintApiMemory['downloadOrderFile']>>) =>
    new Response(d.body, {
      headers: {
        'Content-Type': d.mime,
        'Content-Length': String(d.size),
        'Content-Disposition': `attachment; filename="file"; filename*=UTF-8''${encodeURIComponent(d.filename)}`,
        'X-Content-Type-Options': 'nosniff',
        'Cache-Control': 'private, no-store',
      },
    });

  const pre = (c: Context) => {
    const ifMatch = c.req.header('if-match');
    const idempotencyKey = c.req.header('idempotency-key');
    return {
      ...(ifMatch !== undefined ? { ifMatch } : {}),
      ...(idempotencyKey !== undefined ? { idempotencyKey } : {}),
    };
  };

  const v1 = new Hono();
  v1.use('*', async (c, next) => {
    seenHeaders.push(new Headers(c.req.raw.headers));
    if (behaviour.delayMs) await new Promise((r) => setTimeout(r, behaviour.delayMs));
    if (behaviour.redirectTo) return c.redirect(behaviour.redirectTo, 302);
    if (behaviour.failWith) return c.text('upstream exploded', behaviour.failWith as 500);
    if (behaviour.hugeBodyBytes) {
      // Contract-valid but huge: only a size cap can refuse it.
      const summary = {
        id: randomUUID(),
        reference: 'IMP-0001',
        title: 'x'.repeat(behaviour.hugeBodyBytes),
        revision: 1,
        version: 1,
        status: 'ready',
        createdAt: new Date().toISOString(),
        collectedAt: null,
        printedAt: null,
        approvedAmountCents: null,
      };
      return c.json({ items: [summary], nextCursor: null });
    }
    if (behaviour.rateLimitedFor) {
      return c.json(
        {
          error: { code: 'RATE_LIMITED', message: 'Muitas requisições.', requestId: randomUUID() },
        },
        429,
        { 'Retry-After': String(behaviour.rateLimitedFor) },
      );
    }
    if (c.req.header('authorization') !== `Bearer ${token}`) {
      return c.json(
        { error: { code: 'UNAUTHORIZED', message: 'Não autorizado.', requestId: randomUUID() } },
        401,
      );
    }
    await next();
  });

  v1.get('/orders', async (c) => {
    try {
      const status = c.req.query('status');
      const cursor = c.req.query('cursor');
      const page = await api.listOrders({
        limit: Number(c.req.query('limit') ?? 20),
        ...(status ? { status: status as never } : {}),
        ...(cursor ? { cursor } : {}),
      });
      return json(c, page as never, 200, {});
    } catch (e) {
      return fail(c, e);
    }
  });
  v1.get('/orders/:id', async (c) => {
    try {
      const r = await api.getOrder(c.req.param('id'));
      return json(c, { order: r.value }, 200, { ETag: r.etag });
    } catch (e) {
      return fail(c, e);
    }
  });
  v1.get('/orders/:id/files/:fileId', async (c) => {
    try {
      return await download(await api.downloadOrderFile(c.req.param('id'), c.req.param('fileId')));
    } catch (e) {
      return fail(c, e);
    }
  });
  v1.get('/orders/:id/quotes/:quoteId/file', async (c) => {
    try {
      return await download(await api.downloadQuoteFile(c.req.param('id'), c.req.param('quoteId')));
    } catch (e) {
      return fail(c, e);
    }
  });
  const command = (
    r: { value: unknown; etag: string; status: number; replayed: boolean },
    key: string,
    c: Context,
  ) =>
    json(c, { [key]: r.value }, r.status, {
      ETag: r.etag,
      ...(r.replayed ? { 'Idempotency-Replayed': 'true' } : {}),
    });
  v1.post('/orders/:id/collected', async (c) => {
    try {
      const body = (await c.req.json()) as { revision: number };
      return command(await api.markCollected(c.req.param('id'), body, pre(c)), 'order', c);
    } catch (e) {
      return fail(c, e);
    }
  });
  v1.post('/orders/:id/printed', async (c) => {
    try {
      const body = (await c.req.json()) as { revision: number; quoteId: string };
      return command(await api.markPrinted(c.req.param('id'), body, pre(c)), 'order', c);
    } catch (e) {
      return fail(c, e);
    }
  });
  v1.post('/orders/:id/quotes', async (c) => {
    try {
      const form = await c.req.parseBody({ all: true });
      const keys = Object.keys(form).sort().join(',');
      const file = form.file;
      if (keys !== 'amountCents,file,orderRevision' || !(file instanceof File)) {
        throw new UpstreamRejectedError(
          400,
          'INVALID_REQUEST',
          'Requisição inválida.',
          randomUUID(),
        );
      }
      return command(
        await api.submitQuote(
          c.req.param('id'),
          {
            amountCents: Number(form.amountCents),
            orderRevision: Number(form.orderRevision),
            file: { filename: file.name, bytes: new Uint8Array(await file.arrayBuffer()) },
          },
          pre(c),
        ),
        'order',
        c,
      );
    } catch (e) {
      return fail(c, e);
    }
  });
  v1.get('/monthly-closes/:competence', async (c) => {
    try {
      const r = await api.getMonthlyClose(c.req.param('competence'));
      return json(c, { close: r.value }, 200, { ETag: r.etag });
    } catch (e) {
      return fail(c, e);
    }
  });
  v1.post('/monthly-closes/:competence/invoice', async (c) => {
    try {
      const form = await c.req.parseBody({ all: true });
      const file = form.file;
      if (
        Object.keys(form).sort().join(',') !== 'declaredTotalCents,file' ||
        !(file instanceof File)
      ) {
        throw new UpstreamRejectedError(
          400,
          'INVALID_REQUEST',
          'Requisição inválida.',
          randomUUID(),
        );
      }
      return command(
        await api.submitInvoice(
          c.req.param('competence'),
          {
            declaredTotalCents: Number(form.declaredTotalCents),
            file: { filename: file.name, bytes: new Uint8Array(await file.arrayBuffer()) },
          },
          pre(c),
        ),
        'close',
        c,
      );
    } catch (e) {
      return fail(c, e);
    }
  });
  v1.get('/monthly-closes/:competence/invoice', async (c) => {
    try {
      return await download(await api.downloadInvoice(c.req.param('competence')));
    } catch (e) {
      return fail(c, e);
    }
  });
  for (const path of [
    '/orders',
    '/orders/:id',
    '/orders/:id/collected',
    '/orders/:id/printed',
    '/orders/:id/quotes',
  ]) {
    v1.all(path, methodNotAllowed);
  }
  v1.all('*', (c) =>
    c.json(
      { error: { code: 'NOT_FOUND', message: 'Recurso não encontrado.', requestId: randomUUID() } },
      404,
    ),
  );
  app.route('/api/print-portal/v1', v1);

  const server = serve({ fetch: app.fetch, port: 0, hostname: '127.0.0.1' });
  if (!server.listening)
    await new Promise<void>((resolve) => server.once('listening', () => resolve()));
  const { port } = server.address() as AddressInfo;

  return {
    origin: `http://127.0.0.1:${port}`,
    token,
    api,
    behaviour,
    seenHeaders,
    close: () =>
      new Promise<void>((resolve, reject) =>
        server.close((err) => (err ? reject(err) : resolve())),
      ),
  };
}
