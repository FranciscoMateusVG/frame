// Stateful synthetic HTTP boundary; never connected to Hono production.
import { createHmac, timingSafeEqual } from 'node:crypto';
import { type Context, Hono } from 'hono';
import type { ContentfulStatusCode } from 'hono/utils/http-status';
import { type BatchRuntime, RateError } from './batch-runtime.js';
import { type Batch, BatchError, type Preconditions } from './batch-state.js';
import { multipart } from './batch-upload.js';
import { ControlError, type TrialControl } from './trial-control.js';

const prefix = '/api/print-portal/v2';
const statuses = [
  'open',
  'files_collected',
  'quote_pending',
  'quote_rejected',
  'quote_approved',
  'printed',
  'received',
  'cancelled',
];
function invalid(code = 'INVALID_REQUEST'): never {
  throw new BatchError(400, code);
}
function summary(b: Batch) {
  const { items, currentQuote, cancellationReason, ...rest } = b;
  return rest;
}
function pre(c: Context): Preconditions {
  const key = c.req.header('idempotency-key');
  const etag = c.req.header('if-match');
  if (!key || !etag) throw new BatchError(428, 'PRECONDITION_REQUIRED');
  return { key, etag };
}
async function jsonBody(c: Context, keys: string[]) {
  if (c.req.header('content-type')?.split(';')[0] !== 'application/json') invalid();
  const reader = c.req.raw.body?.getReader();
  const parts: Uint8Array[] = [];
  let size = 0;
  if (!reader) invalid();
  try {
    while (true) {
      const r = await reader.read();
      if (r.done) break;
      size += r.value.length;
      if (size > 16384) {
        await reader.cancel();
        invalid();
      }
      parts.push(r.value);
    }
  } finally {
    reader.releaseLock();
  }
  let value: unknown;
  try {
    value = JSON.parse(Buffer.concat(parts).toString('utf8'));
  } catch {
    invalid();
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid();
  const obj = value as Record<string, unknown>;
  if (Object.keys(obj).length !== keys.length || Object.keys(obj).some((k) => !keys.includes(k)))
    invalid();
  return obj;
}

function param(c: Context, name: string) {
  const value = c.req.param(name);
  if (!value) invalid();
  return value;
}
function listQuery(url: URL) {
  const allowed = ['status', 'limit', 'cursor'];
  if (
    [...url.searchParams.keys()].some(
      (k) => !allowed.includes(k) || url.searchParams.getAll(k).length !== 1,
    )
  )
    invalid();
  const status = url.searchParams.get('status');
  if (status !== null && !statuses.includes(status)) invalid();
  const raw = url.searchParams.get('limit') ?? '20';
  if (!/^[1-9]\d*$/.test(raw) || Number(raw) > 100) invalid();
  return { status, limit: Number(raw), cursor: url.searchParams.get('cursor') };
}
function afterCursor(
  cursor: string | null,
  status: string | null,
  control: TrialControl<BatchRuntime>,
  sign: (s: string) => string,
): string | null {
  if (cursor === null) return null;
  const parts = cursor.split('.');
  const data = parts[0];
  const signature = parts[1];
  if (parts.length !== 2 || !data || !signature || sign(data) !== signature)
    invalid('INVALID_CURSOR');
  try {
    const d = JSON.parse(Buffer.from(data, 'base64url').toString('utf8'));
    if (
      d.status !== status ||
      d.boot !== control.boot_id ||
      d.generation !== control.status().generation ||
      typeof d.id !== 'string'
    )
      invalid('INVALID_CURSOR');
    return d.id;
  } catch {
    return invalid('INVALID_CURSOR');
  }
}

function download(c: Context, value: ReturnType<BatchRuntime['memberFile']>) {
  c.header('Content-Type', value.file.mime);
  c.header('Content-Length', String(value.bytes.length));
  c.header('X-Content-Type-Options', 'nosniff');
  const filename = encodeURIComponent(value.file.name).replace(
    /[!'()*]/g,
    (ch) => `%${ch.charCodeAt(0).toString(16).toUpperCase()}`,
  );
  c.header('Content-Disposition', `attachment; filename="download"; filename*=UTF-8''${filename}`);
  return c.body(new Uint8Array(value.bytes));
}

function errorResponse(error: Error) {
  if (error instanceof ControlError) return { code: 'UPSTREAM_UNAVAILABLE', status: 503 };
  if (error instanceof BatchError)
    return {
      code: error.status < 500 || error.status === 503 ? error.code : 'INTERNAL',
      status: error.status,
    };
  return { code: 'INTERNAL', status: 500 };
}

export function createBatchApp(options: { control: TrialControl<BatchRuntime>; token: string }) {
  const { control, token } = options;
  const app = new Hono();
  const sign = (s: string) => createHmac('sha256', token).update(s).digest('base64url');
  app.use('*', async (c, next) => {
    c.header('Cache-Control', 'no-store');
    const auth = Buffer.from(c.req.header('authorization') ?? '');
    const want = Buffer.from(`Bearer ${token}`);
    if (auth.length !== want.length || !timingSafeEqual(auth, want))
      return c.json(
        { error: { code: 'UNAUTHORIZED', message: 'Não autorizado', requestId: 'ttp' } },
        401,
      );
    const state = control.current();
    state.rate(c.req.method === 'GET' ? 'read' : 'command');
    if (c.req.method === 'POST' && /\/(quotes|invoice)$/.test(new URL(c.req.url).pathname))
      state.rate('upload');
    await next();
  });
  app.onError((error, c) => {
    const { code, status } = errorResponse(error);
    if (error instanceof RateError) c.header('Retry-After', String(error.retryAfter));
    else if (status === 503) c.header('Retry-After', '1');
    return c.json(
      {
        error: {
          code,
          message: 'Falha sintética',
          requestId: 'ttp',
        },
      },
      status as ContentfulStatusCode,
    );
  });
  app.get(`${prefix}/batches`, (c) => {
    const { status, limit, cursor } = listQuery(new URL(c.req.url));
    const after = afterCursor(cursor, status, control, sign);
    const rows = control
      .current()
      .list()
      .filter((b) => status === null || b.status === status);
    const index = after === null ? 0 : rows.findIndex((b) => b.id === after) + 1;
    if (after !== null && index === 0) invalid('INVALID_CURSOR');
    const items = rows.slice(index, index + limit).map(summary);
    let nextCursor: string | null = null;
    if (index + limit < rows.length) {
      const data = Buffer.from(
        JSON.stringify({
          id: items[items.length - 1]?.id,
          status,
          boot: control.boot_id,
          generation: control.status().generation,
        }),
      ).toString('base64url');
      nextCursor = `${data}.${sign(data)}`;
    }
    return c.json({ items, nextCursor });
  });
  app.get(`${prefix}/batches/open`, (c) => {
    const b = control.current().open();
    if (b) c.header('ETag', control.current().etag(b.id));
    return c.json({ batch: b });
  });
  app.get(`${prefix}/batches/:id`, (c) => {
    const s = control.current();
    const b = s.get(param(c, 'id'));
    c.header('ETag', s.etag(b.id));
    return c.json({ batch: b });
  });
  app.post(`${prefix}/batches/:id/collected`, async (c) => {
    const p = pre(c);
    const r = await control.command(async (s) => {
      await jsonBody(c, []);
      return s.collect(param(c, 'id'), p);
    });
    c.header('ETag', r.etag);
    if (r.replayed) c.header('Idempotency-Replayed', 'true');
    return c.json(r.body, r.status as ContentfulStatusCode);
  });
  app.post(`${prefix}/batches/:id/printed`, async (c) => {
    const p = pre(c);
    const r = await control.command(async (s) => {
      const b = await jsonBody(c, ['quoteId']);
      if (
        typeof b.quoteId !== 'string' ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
          b.quoteId,
        )
      )
        invalid();
      return s.print(param(c, 'id'), b.quoteId, p);
    });
    c.header('ETag', r.etag);
    if (r.replayed) c.header('Idempotency-Replayed', 'true');
    return c.json(r.body, r.status as ContentfulStatusCode);
  });
  app.get(`${prefix}/batches/:id/orders/:orderId/files/:fileId`, (c) =>
    download(
      c,
      control.current().memberFile(param(c, 'id'), param(c, 'orderId'), param(c, 'fileId')),
    ),
  );
  app.get(`${prefix}/batches/:id/quotes/:quoteId/file`, (c) =>
    download(c, control.current().quoteFile(param(c, 'id'), param(c, 'quoteId'))),
  );
  app.post(`${prefix}/batches/:id/quotes`, async (c) => {
    const p = pre(c);
    const r = await control.command(async (s) => {
      s.get(param(c, 'id')); // Existence/ownership before buffering a file.
      const { upload, amount } = await multipart(c, 'amountCents');
      const reply = s.uploadQuote(param(c, 'id'), upload, amount, p);
      if (s.consumeQuoteFault(reply.replayed)) throw new BatchError(503, 'UPSTREAM_UNAVAILABLE');
      return reply;
    });
    c.header('ETag', r.etag);
    if (r.replayed) c.header('Idempotency-Replayed', 'true');
    return c.json(r.body, r.status as ContentfulStatusCode);
  });
  app.get(`${prefix}/monthly-closes/:competence`, (c) => {
    const s = control.current();
    const competence = param(c, 'competence');
    const body = s.month(competence);
    c.header('ETag', s.monthEtag(competence));
    return c.json(body);
  });
  app.post(`${prefix}/monthly-closes/:competence/invoice`, async (c) => {
    const p = pre(c);
    const r = await control.command(async (s) => {
      const competence = param(c, 'competence');
      s.month(competence);
      const { upload, amount } = await multipart(c, 'declaredTotalCents');
      return s.uploadInvoice(competence, upload, amount, p);
    });
    c.header('ETag', r.etag);
    if (r.replayed) c.header('Idempotency-Replayed', 'true');
    return c.json(r.body, r.status as ContentfulStatusCode);
  });
  app.get(`${prefix}/monthly-closes/:competence/invoice`, (c) =>
    download(c, control.current().invoiceFile(param(c, 'competence'))),
  );
  for (const path of [
    '/batches',
    '/batches/open',
    '/batches/:id',
    '/batches/:id/collected',
    '/batches/:id/printed',
    '/batches/:id/quotes',
    '/batches/:id/orders/:orderId/files/:fileId',
    '/batches/:id/quotes/:quoteId/file',
    '/monthly-closes/:competence',
    '/monthly-closes/:competence/invoice',
  ])
    app.all(prefix + path, (c) =>
      c.json(
        {
          error: { code: 'METHOD_NOT_ALLOWED', message: 'Método não permitido', requestId: 'ttp' },
        },
        405,
      ),
    );
  app.notFound((c) =>
    c.json({ error: { code: 'NOT_FOUND', message: 'Não encontrado', requestId: 'ttp' } }, 404),
  );
  return app;
}
