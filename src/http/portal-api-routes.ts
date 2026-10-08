/**
 * Portal JSON API (spec §4.5):
 *   GET/POST/DELETE /api/session
 *   /api/print/v1/*  — the ten service routes of §4.3, authenticated by the
 *                      session cookie instead of the bearer.
 *
 * The BFF is a fixed router, not a proxy: every route is spelled out, ids
 * are re-encoded as path segments by the adapter, bodies are re-validated
 * and rebuilt, and nothing from the browser (Authorization, cookies, host,
 * extra headers) is forwarded upstream.
 */
import { Hono } from 'hono';
import { z } from 'zod';
import type { Preconditions, Upload } from '../adapters/print-api.js';
import { parseCentsString } from '../domain/money.js';
import { isValidCompetence } from '../domain/monthly-close.js';
import { ORDER_STATUSES } from '../domain/print-order.js';
import { InvalidRequestError } from '../errors/invalid-request.error.js';
import { authenticateSession } from '../use-cases/authenticate-session.js';
import { collectOrderFiles } from '../use-cases/collect-order-files.js';
import { downloadInvoice } from '../use-cases/download-invoice.js';
import { downloadOrderFile } from '../use-cases/download-order-file.js';
import { downloadQuoteFile } from '../use-cases/download-quote-file.js';
import { getMonthlyClose } from '../use-cases/get-monthly-close.js';
import { getOrder } from '../use-cases/get-order.js';
import { listOrders } from '../use-cases/list-orders.js';
import { logIn } from '../use-cases/log-in.js';
import { logOut } from '../use-cases/log-out.js';
import { markOrderPrinted } from '../use-cases/mark-order-printed.js';
import { openSession } from '../use-cases/open-session.js';
import { submitInvoice } from '../use-cases/submit-invoice.js';
import { submitQuote } from '../use-cases/submit-quote.js';
import {
  clearSessionCookies,
  clientKey,
  DOCUMENT_MAX_BYTES,
  downloadResponse,
  errorToJson,
  jsonError,
  limitBody,
  originAllowed,
  type PortalContext,
  type PortalDeps,
  type PortalEnv,
  preSessionIdFrom,
  relayHeader,
  sessionIdFrom,
  setPreSessionCookie,
  setSessionCookie,
  UPLOAD_BODY_MAX_BYTES,
} from './portal-http.js';

const LoginBody = z.object({ password: z.string() }).strict();
const CollectedBody = z.object({ revision: z.number().int().min(1).max(1_000_000) }).strict();
const PrintedBody = z
  .object({
    revision: z.number().int().min(1).max(1_000_000),
    quoteId: z.string().regex(/^[0-9a-fA-F-]{36}$/),
  })
  .strict();
const ListQuery = z.object({
  status: z.enum(ORDER_STATUSES).optional(),
  limit: z
    .string()
    .regex(/^[1-9][0-9]{0,2}$/)
    .transform(Number)
    .pipe(z.number().max(100))
    .optional(),
  cursor: z.string().min(1).max(512).optional(),
});

const NO_STORE = { 'Cache-Control': 'no-store' } as const;

/** JSON object body (content-type application/json) or undefined. */
async function readJsonObject(c: PortalContext): Promise<unknown> {
  if (!/^application\/json(\s*;|$)/i.test(c.req.header('content-type') ?? '')) return undefined;
  try {
    const parsed: unknown = JSON.parse(await c.req.text());
    return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed
      : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Multipart with exactly `fields` + one non-empty `file` (≤ 5 MiB); repeated
 * or unknown fields are refused. Returns the text fields and the upload.
 */
export async function readUpload(
  c: PortalContext,
  fields: readonly string[],
): Promise<{ fields: Record<string, string>; file: Upload } | 'too_large'> {
  if (!/^multipart\/form-data(\s*;|$)/i.test(c.req.header('content-type') ?? '')) {
    throw new InvalidRequestError('content-type');
  }
  const form = (await c.req.parseBody({ all: true }).catch(() => null)) as Record<
    string,
    unknown
  > | null;
  if (!form) throw new InvalidRequestError('multipart');
  const expected = [...fields, 'file'].sort().join(',');
  if (Object.keys(form).sort().join(',') !== expected) throw new InvalidRequestError('fields');
  const file = form.file;
  if (!(file instanceof File) || file.size === 0) throw new InvalidRequestError('file');
  if (file.size > DOCUMENT_MAX_BYTES) return 'too_large';
  const values: Record<string, string> = {};
  for (const name of fields) {
    const value = form[name];
    if (typeof value !== 'string') throw new InvalidRequestError(name);
    values[name] = value;
  }
  return {
    fields: values,
    file: { filename: file.name || 'documento', bytes: new Uint8Array(await file.arrayBuffer()) },
  };
}

function preconditions(c: PortalContext): Preconditions {
  const ifMatch = relayHeader(c, 'if-match');
  const idempotencyKey = relayHeader(c, 'idempotency-key');
  return {
    ...(ifMatch !== undefined ? { ifMatch } : {}),
    ...(idempotencyKey !== undefined ? { idempotencyKey } : {}),
  };
}

function commandJson(
  c: PortalContext,
  key: 'order' | 'close',
  result: { value: unknown; etag: string; status: 200 | 201; replayed: boolean },
): Response {
  const headers: Record<string, string> = { ...NO_STORE, ETag: result.etag };
  if (result.replayed) headers['Idempotency-Replayed'] = 'true';
  return c.json({ [key]: result.value }, result.status, headers);
}

const tooLarge = (c: PortalContext) =>
  jsonError(c, 413, 'FILE_TOO_LARGE', 'Arquivo acima de 5 MB.');

export function portalApiRoutes(deps: PortalDeps): Hono<PortalEnv> {
  const app = new Hono<PortalEnv>();
  const { logger } = deps;

  app.onError((error, c) => errorToJson(c, error, logger));

  // ── session ──

  app.get('/api/session', async (c) => {
    const result = await openSession(deps.session, {
      sessionIds: [sessionIdFrom(c), preSessionIdFrom(c)],
    });
    if (result.created) setPreSessionCookie(c, result.session.id);
    return c.json(
      {
        authenticated: result.session.authenticated,
        csrfToken: result.session.csrfToken,
        expiresAt: result.expiresAt?.toISOString() ?? null,
      },
      200,
      NO_STORE,
    );
  });

  app.post('/api/session', async (c) => {
    if (!originAllowed(c, deps.portalOrigin)) {
      return jsonError(c, 403, 'CSRF_FAILED', 'Falha na verificação de segurança da requisição.');
    }
    const body = LoginBody.safeParse(await readJsonObject(c));
    const result = await logIn(deps.session, {
      sessionId: preSessionIdFrom(c),
      csrfToken: c.req.header('x-csrf-token'),
      clientKey: clientKey(c, deps.trustedProxies),
      password: body.success ? body.data.password : undefined,
    });
    setSessionCookie(c, result.session.id);
    return c.json(
      {
        authenticated: true,
        csrfToken: result.session.csrfToken,
        expiresAt: result.expiresAt.toISOString(),
      },
      200,
      NO_STORE,
    );
  });

  app.delete('/api/session', async (c) => {
    if (!originAllowed(c, deps.portalOrigin)) {
      return jsonError(c, 403, 'CSRF_FAILED', 'Falha na verificação de segurança da requisição.');
    }
    await logOut(deps.session, {
      sessionId: sessionIdFrom(c),
      csrfToken: c.req.header('x-csrf-token'),
    });
    clearSessionCookies(c);
    return c.body(null, 204, NO_STORE);
  });

  app.all('/api/session', (c) => jsonError(c, 405, 'METHOD_NOT_ALLOWED', 'Método não permitido.'));

  // ── /api/print/v1 ──

  const v1 = new Hono<PortalEnv>();
  v1.onError((error, c) => errorToJson(c, error, logger));

  // Every route needs a live authenticated session; POSTs also need our
  // exact Origin and the session's CSRF token.
  v1.use('*', async (c, next) => {
    // The bearer lives only on the server; a browser-supplied Authorization
    // is refused, never forwarded.
    if (c.req.header('authorization') !== undefined) {
      return jsonError(c, 400, 'INVALID_REQUEST', 'Requisição inválida.');
    }
    const isCommand = c.req.method === 'POST';
    await authenticateSession(deps.session, {
      sessionId: sessionIdFrom(c),
      ...(isCommand ? { csrf: { token: c.req.header('x-csrf-token') } } : {}),
    });
    if (isCommand && !originAllowed(c, deps.portalOrigin)) {
      return jsonError(c, 403, 'CSRF_FAILED', 'Falha na verificação de segurança da requisição.');
    }
    await next();
  });

  v1.get('/orders', async (c) => {
    const q = ListQuery.safeParse(c.req.query());
    if (!q.success) throw new InvalidRequestError('query');
    const page = await listOrders(deps.print, {
      limit: q.data.limit ?? 20,
      ...(q.data.status ? { status: q.data.status } : {}),
      ...(q.data.cursor ? { cursor: q.data.cursor } : {}),
    });
    return c.json(page, 200, NO_STORE);
  });

  v1.get('/orders/:id', async (c) => {
    const { value, etag } = await getOrder(deps.print, c.req.param('id'));
    return c.json({ order: value }, 200, { ...NO_STORE, ETag: etag });
  });

  v1.get('/orders/:id/files/:fileId', async (c) =>
    downloadResponse(
      await downloadOrderFile(deps.print, {
        orderId: c.req.param('id'),
        fileId: c.req.param('fileId'),
      }),
    ),
  );

  v1.get('/orders/:id/quotes/:quoteId/file', async (c) =>
    downloadResponse(
      await downloadQuoteFile(deps.print, {
        orderId: c.req.param('id'),
        quoteId: c.req.param('quoteId'),
      }),
    ),
  );

  v1.post('/orders/:id/collected', async (c) => {
    const body = CollectedBody.safeParse(await readJsonObject(c));
    if (!body.success) throw new InvalidRequestError('body');
    const result = await collectOrderFiles(
      deps.print,
      { orderId: c.req.param('id'), revision: body.data.revision },
      preconditions(c),
    );
    return commandJson(c, 'order', result);
  });

  v1.post('/orders/:id/printed', async (c) => {
    const body = PrintedBody.safeParse(await readJsonObject(c));
    if (!body.success) throw new InvalidRequestError('body');
    const result = await markOrderPrinted(
      deps.print,
      { orderId: c.req.param('id'), revision: body.data.revision, quoteId: body.data.quoteId },
      preconditions(c),
    );
    return commandJson(c, 'order', result);
  });

  const uploadLimit = limitBody(UPLOAD_BODY_MAX_BYTES, tooLarge);

  v1.post('/orders/:id/quotes', uploadLimit, async (c) => {
    const upload = await readUpload(c, ['amountCents', 'orderRevision']);
    if (upload === 'too_large') return tooLarge(c);
    const amountCents = parseCentsString(upload.fields.amountCents ?? '');
    const orderRevision = parseCentsString(upload.fields.orderRevision ?? '');
    if (amountCents === null || orderRevision === null) throw new InvalidRequestError('fields');
    const result = await submitQuote(
      deps.print,
      { orderId: c.req.param('id'), orderRevision, amountCents, file: upload.file },
      preconditions(c),
    );
    return commandJson(c, 'order', result);
  });

  v1.get('/monthly-closes/:competence', async (c) => {
    const competence = c.req.param('competence');
    if (!isValidCompetence(competence)) {
      return jsonError(c, 400, 'INVALID_COMPETENCE', 'Competência inválida.');
    }
    const { value, etag } = await getMonthlyClose(deps.print, competence);
    return c.json({ close: value }, 200, { ...NO_STORE, ETag: etag });
  });

  v1.post('/monthly-closes/:competence/invoice', uploadLimit, async (c) => {
    const competence = c.req.param('competence');
    if (!isValidCompetence(competence)) {
      return jsonError(c, 400, 'INVALID_COMPETENCE', 'Competência inválida.');
    }
    const upload = await readUpload(c, ['declaredTotalCents']);
    if (upload === 'too_large') return tooLarge(c);
    const declaredTotalCents = parseCentsString(upload.fields.declaredTotalCents ?? '');
    if (declaredTotalCents === null) throw new InvalidRequestError('fields');
    const result = await submitInvoice(
      deps.print,
      { competence, declaredTotalCents, file: upload.file },
      preconditions(c),
    );
    return commandJson(c, 'close', result);
  });

  v1.get('/monthly-closes/:competence/invoice', async (c) => {
    const competence = c.req.param('competence');
    if (!isValidCompetence(competence)) {
      return jsonError(c, 400, 'INVALID_COMPETENCE', 'Competência inválida.');
    }
    return downloadResponse(await downloadInvoice(deps.print, competence));
  });

  // Known resources with an unlisted method → 405; anything else → 404.
  for (const path of [
    '/orders',
    '/orders/:id',
    '/orders/:id/files/:fileId',
    '/orders/:id/collected',
    '/orders/:id/quotes',
    '/orders/:id/quotes/:quoteId/file',
    '/orders/:id/printed',
    '/monthly-closes/:competence',
    '/monthly-closes/:competence/invoice',
  ]) {
    v1.all(path, (c) => jsonError(c, 405, 'METHOD_NOT_ALLOWED', 'Método não permitido.'));
  }
  v1.all('*', (c) => jsonError(c, 404, 'NOT_FOUND', 'Recurso não encontrado.'));

  app.route('/api/print/v1', v1);
  app.all('/api/*', (c) => jsonError(c, 404, 'NOT_FOUND', 'Recurso não encontrado.'));
  return app;
}
