/**
 * Server-rendered pages (spec §7): /login, /orders, /orders/:id, /invoices,
 * plus their form actions. Forms post to the portal itself with a hidden
 * CSRF token and our exact Origin; every command carries the If-Match ETag
 * the page was rendered with and an Idempotency-Key minted at render time.
 *
 * After an ambiguous failure (timeout/503) the page is re-rendered with the
 * SAME key and ETag while the order is unchanged, so "repeat" is the same
 * intent and can never double-apply; "Consultar novamente" is a plain GET.
 */
import { randomUUID } from 'node:crypto';
import { Hono } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import type { Upload } from '../adapters/print-api.js';
import { parseBrlToCents } from '../domain/money.js';
import { competenceOf, isValidCompetence, previousCompetence } from '../domain/monthly-close.js';
import type { PortalSession } from '../domain/portal-session.js';
import { isOrderStatus, type Order } from '../domain/print-order.js';
import { CsrfFailedError } from '../errors/csrf-failed.error.js';
import { InvalidCredentialsError } from '../errors/invalid-credentials.error.js';
import { InvalidRequestError } from '../errors/invalid-request.error.js';
import { LoginRateLimitedError } from '../errors/login-rate-limited.error.js';
import { UnauthenticatedError } from '../errors/unauthenticated.error.js';
import { UpstreamRejectedError } from '../errors/upstream-rejected.error.js';
import { UpstreamUnavailableError } from '../errors/upstream-unavailable.error.js';
import { authenticateSession } from '../use-cases/authenticate-session.js';
import { collectOrderFiles } from '../use-cases/collect-order-files.js';
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
  compact,
  DOCUMENT_MAX_BYTES,
  originAllowed,
  type PortalContext,
  type PortalDeps,
  type PortalEnv,
  preSessionIdFrom,
  sessionIdFrom,
  setPreSessionCookie,
  setSessionCookie,
  UPLOAD_BODY_MAX_BYTES,
} from './portal-http.js';
import {
  type ActionForm,
  type Banner,
  errorPage,
  invoicesPage,
  loginPage,
  orderPage,
  ordersPage,
  orderUnavailablePage,
} from './portal-views.js';

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const ETAG_RE = /^"[^"\r\n]{1,200}"$/;

const SUCCESS: Record<string, string> = {
  collected: 'Retirada confirmada.',
  quote: 'Orçamento enviado. Aguardando aprovação do Financeiro.',
  printed: 'Impressão confirmada.',
  invoice: 'NF enviada. Aguardando conferência.',
};

const UNAVAILABLE: Banner = {
  kind: 'error',
  text: 'Serviço indisponível no momento. Não sabemos se a operação foi concluída: use “Consultar novamente” antes de repetir. Repetir com o mesmo formulário não duplica a operação.',
};

/** Human message for a contract error code. */
function rejectionBanner(error: UpstreamRejectedError): Banner {
  switch (error.code) {
    case 'VERSION_MISMATCH':
      return { kind: 'error', text: 'Pedido atualizado; confira novamente.' };
    case 'INVALID_STATE':
      return {
        kind: 'error',
        text: 'Esta ação não é mais possível no estado atual. Confira novamente.',
      };
    case 'IDEMPOTENCY_CONFLICT':
      return {
        kind: 'error',
        text: 'Esta operação já foi enviada com outros dados. Confira o pedido e tente de novo.',
      };
    case 'OPERATION_IN_PROGRESS':
      return {
        kind: 'info',
        text: 'Operação em andamento. Aguarde alguns segundos e consulte novamente.',
      };
    case 'FILE_TOO_LARGE':
      return { kind: 'error', text: 'Arquivo acima de 5 MB.' };
    case 'UNSUPPORTED_MEDIA_TYPE':
      return {
        kind: 'error',
        text: 'Formato de arquivo não aceito. Envie PDF, JPEG, PNG ou WebP.',
      };
    case 'PERIOD_OPEN':
      return { kind: 'error', text: 'A competência ainda não foi encerrada.' };
    case 'EMPTY_CLOSE':
      return { kind: 'error', text: 'Não há pedidos impressos nesta competência.' };
    case 'RATE_LIMITED':
      return { kind: 'error', text: 'Muitas requisições. Tente novamente em instantes.' };
    case 'NOT_FOUND':
      return { kind: 'error', text: 'Pedido não encontrado.' };
    default:
      return {
        kind: 'error',
        text: 'A operação foi recusada. Confira os dados e tente novamente.',
      };
  }
}

type FormFields = Record<string, string | File | (string | File)[]>;

function text(form: FormFields, name: string): string | undefined {
  const value = form[name];
  return typeof value === 'string' ? value : undefined;
}

function isUpstreamError(
  error: unknown,
): error is UpstreamRejectedError | UpstreamUnavailableError {
  return error instanceof UpstreamRejectedError || error instanceof UpstreamUnavailableError;
}

/**
 * Form state for the next render. Same ETag as the failed attempt → nothing
 * changed upstream: keep its key so a repeat is the same intent. Otherwise a
 * fresh key for a fresh decision.
 */
function nextForm(etag: string, retry: ActionForm | undefined, keepAmount: boolean): ActionForm {
  const reuse = retry !== undefined && retry.etag === etag;
  const amountText = reuse || keepAmount ? retry?.amountText : undefined;
  return {
    idempotencyKey: reuse ? retry.idempotencyKey : randomUUID(),
    etag,
    ...(amountText !== undefined ? { amountText } : {}),
  };
}

type DocumentForm =
  | { readonly ok: true; readonly amountCents: number; readonly upload: Upload }
  | { readonly ok: false; readonly message: string; readonly status: number };

/** BRL amount + one document from an upload form (quote or NF). */
async function readDocumentForm(
  form: FormFields,
  labels: { amount: string; file: string; fallbackName: string },
): Promise<DocumentForm> {
  const amountCents = parseBrlToCents(text(form, 'amount') ?? '');
  const file = form.file;
  if (amountCents === null) {
    return {
      ok: false,
      status: 400,
      message: `${labels.amount} inválido. Use o formato 1.234,56.`,
    };
  }
  if (!(file instanceof File) || file.size === 0) {
    return { ok: false, status: 400, message: `Selecione o ${labels.file}.` };
  }
  if (file.size > DOCUMENT_MAX_BYTES) {
    return { ok: false, status: 413, message: 'Arquivo acima de 5 MB.' };
  }
  return {
    ok: true,
    amountCents,
    upload: {
      filename: file.name || labels.fallbackName,
      bytes: new Uint8Array(await file.arrayBuffer()),
    },
  };
}

/**
 * Banner/status/form for re-rendering after a failed NF command. A refused
 * command's key is released upstream and may be reused — except after a
 * conflict, where it is bound to another intent.
 */
function retryAfterFailure(
  error: UpstreamRejectedError | UpstreamUnavailableError,
  attempt: ActionForm,
): { banner: Banner; status: number; retry: ActionForm } {
  if (error instanceof UpstreamUnavailableError) {
    return { banner: UNAVAILABLE, status: 503, retry: attempt };
  }
  const retry =
    error.code === 'IDEMPOTENCY_CONFLICT' ? { ...attempt, idempotencyKey: randomUUID() } : attempt;
  return { banner: rejectionBanner(error), status: error.status, retry };
}

function ordersHref(status: string | undefined): string {
  return status ? `/orders?status=${status}` : '/orders';
}

/** Login failure → status + message, or null for unexpected errors. */
function loginFailure(error: unknown): { status: number; text: string } | null {
  if (error instanceof InvalidCredentialsError) return { status: 401, text: 'Senha incorreta.' };
  if (error instanceof LoginRateLimitedError) {
    const minutes = Math.max(1, Math.ceil(error.retryAfterSeconds / 60));
    return {
      status: 429,
      text: `Muitas tentativas. Tente novamente em ${minutes} minuto${minutes > 1 ? 's' : ''}.`,
    };
  }
  if (error instanceof InvalidRequestError) return { status: 400, text: 'Informe a senha.' };
  if (error instanceof CsrfFailedError) {
    return { status: 403, text: 'Sessão de login expirada. Tente novamente.' };
  }
  return null;
}

/** /orders query: status filter, cursor and the back-stack for "Anterior". */
function ordersQuery(c: PortalContext) {
  const statusParam = c.req.query('status');
  const cursorParam = c.req.query('cursor');
  return {
    status: isOrderStatus(statusParam) ? statusParam : undefined,
    cursor: cursorParam && cursorParam.length <= 512 ? cursorParam : undefined,
    back: (c.req.queries('back') ?? []).filter((b) => b.length <= 512).slice(-50),
  };
}

function successBanner(c: PortalContext): { banner?: Banner } {
  const done = c.req.query('ok');
  const message = done ? SUCCESS[done] : undefined;
  return message ? { banner: { kind: 'success', text: message } } : {};
}

export function portalHtmlRoutes(deps: PortalDeps): Hono<PortalEnv> {
  const app = new Hono<PortalEnv>();

  /** Authenticated session or a redirect to /login (no external returnTo). */
  async function sessionOrLogin(
    c: PortalContext,
    csrfToken?: string | undefined,
  ): Promise<PortalSession | Response> {
    try {
      return await authenticateSession(deps.session, {
        sessionId: sessionIdFrom(c),
        ...(csrfToken !== undefined || c.req.method === 'POST'
          ? { csrf: { token: csrfToken } }
          : {}),
      });
    } catch (error) {
      if (error instanceof UnauthenticatedError) return c.redirect('/login', 303);
      if (error instanceof CsrfFailedError) return forbidden(c);
      throw error;
    }
  }

  function forbidden(c: PortalContext): Response | Promise<Response> {
    return c.html(
      errorPage('Acesso negado', {
        kind: 'error',
        text: 'Falha na verificação de segurança. Recarregue a página e tente novamente.',
      }),
      403,
    );
  }

  /** Parse a form post after checking Origin. */
  async function readForm(c: PortalContext): Promise<FormFields | null> {
    if (!originAllowed(c, deps.portalOrigin)) return null;
    return (await c.req.parseBody({ all: true }).catch(() => ({}))) as FormFields;
  }

  /** The order, or the error page to show instead. */
  async function loadOrder(
    c: PortalContext,
    session: PortalSession,
    orderId: string,
    opts: { banner?: Banner; status?: number },
  ): Promise<{ value: Order; etag: string } | Response> {
    try {
      return await getOrder(deps.print, orderId);
    } catch (error) {
      if (error instanceof UpstreamRejectedError && error.status === 404) {
        const notFound: Banner = { kind: 'error', text: 'Pedido não encontrado.' };
        return c.html(errorPage('Pedido não encontrado', notFound, session.csrfToken), 404);
      }
      if (!isUpstreamError(error)) throw error;
      return c.html(
        orderUnavailablePage(session.csrfToken, orderId, opts.banner ?? UNAVAILABLE),
        (opts.status ?? 503) as 503,
      );
    }
  }

  async function renderOrder(
    c: PortalContext,
    session: PortalSession,
    orderId: string,
    opts: { banner?: Banner; status?: number; retry?: ActionForm } = {},
  ): Promise<Response> {
    const tagged = await loadOrder(c, session, orderId, opts);
    if (tagged instanceof Response) return tagged;
    return c.html(
      orderPage({
        csrfToken: session.csrfToken,
        order: tagged.value,
        form: nextForm(tagged.etag, opts.retry, false),
        ...(opts.banner ? { banner: opts.banner } : {}),
      }),
      (opts.status ?? 200) as 200,
    );
  }

  /** Common failure handling for order commands. */
  async function orderCommandFailed(
    c: PortalContext,
    session: PortalSession,
    orderId: string,
    error: unknown,
    attempt: ActionForm,
  ): Promise<Response> {
    if (error instanceof UpstreamUnavailableError) {
      return renderOrder(c, session, orderId, { banner: UNAVAILABLE, status: 503, retry: attempt });
    }
    if (error instanceof UpstreamRejectedError) {
      return renderOrder(c, session, orderId, {
        banner: rejectionBanner(error),
        status: error.status,
        ...(error.code === 'OPERATION_IN_PROGRESS' ? { retry: attempt } : {}),
      });
    }
    throw error;
  }

  /** Origin + session + CSRF for a form command; a Response when refused. */
  async function beginCommand(
    c: PortalContext,
  ): Promise<{ form: FormFields; session: PortalSession } | Response> {
    const form = await readForm(c);
    if (!form) return forbidden(c);
    const session = await sessionOrLogin(c, text(form, '_csrf'));
    return session instanceof Response ? session : { form, session };
  }

  /** Validated hidden command fields, or null. */
  function commandFields(form: FormFields): { key: string; etag: string } | null {
    const key = text(form, 'idempotencyKey');
    const etag = text(form, 'etag');
    if (!key || !UUID_RE.test(key) || !etag || !ETAG_RE.test(etag)) return null;
    return { key, etag };
  }

  function badRequest(c: PortalContext, session: PortalSession, orderId: string, message: string) {
    return renderOrder(c, session, orderId, {
      banner: { kind: 'error', text: message },
      status: 400,
    });
  }

  // ── login / logout ──

  app.get('/', (c) => c.redirect('/orders', 302));

  app.get('/login', async (c) => {
    const result = await openSession(deps.session, {
      sessionIds: [sessionIdFrom(c), preSessionIdFrom(c)],
    });
    if (result.session.authenticated) return c.redirect('/orders', 302);
    if (result.created) setPreSessionCookie(c, result.session.id);
    return c.html(loginPage(result.session.csrfToken));
  });

  app.post('/login', async (c) => {
    const form = await readForm(c);
    if (!form) return forbidden(c);
    try {
      const result = await logIn(deps.session, {
        sessionId: preSessionIdFrom(c),
        csrfToken: text(form, '_csrf'),
        clientKey: clientKey(c, deps.trustedProxies),
        password: text(form, 'password'),
      });
      setSessionCookie(c, result.session.id);
      return c.redirect('/orders', 303);
    } catch (error) {
      const failure = loginFailure(error);
      if (!failure) throw error;
      if (error instanceof LoginRateLimitedError) {
        c.header('Retry-After', String(error.retryAfterSeconds));
      }
      const fresh = await openSession(deps.session, {
        sessionIds: [sessionIdFrom(c), preSessionIdFrom(c)],
      });
      if (fresh.created) setPreSessionCookie(c, fresh.session.id);
      return c.html(
        loginPage(fresh.session.csrfToken, { kind: 'error', text: failure.text }),
        failure.status as 401,
      );
    }
  });

  app.post('/logout', async (c) => {
    const form = await readForm(c);
    if (!form) return forbidden(c);
    try {
      await logOut(deps.session, { sessionId: sessionIdFrom(c), csrfToken: text(form, '_csrf') });
    } catch (error) {
      if (error instanceof CsrfFailedError) return forbidden(c);
      throw error;
    }
    clearSessionCookies(c);
    return c.redirect('/login', 303);
  });

  // ── orders ──

  app.get('/orders', async (c) => {
    const session = await sessionOrLogin(c);
    if (session instanceof Response) return session;
    const { status, cursor, back } = ordersQuery(c);
    try {
      const page = await listOrders(deps.print, { limit: 20, ...compact({ status, cursor }) });
      return c.html(ordersPage({ csrfToken: session.csrfToken, status, page, cursor, back }));
    } catch (error) {
      if (!isUpstreamError(error)) throw error;
      if (error.code === 'INVALID_CURSOR') return c.redirect(ordersHref(status), 302);
      const httpStatus = error instanceof UpstreamRejectedError ? error.status : 503;
      return c.html(
        ordersPage({ csrfToken: session.csrfToken, status, page: null, cursor, back }),
        httpStatus as 503,
      );
    }
  });

  app.get('/orders/:id', async (c) => {
    const session = await sessionOrLogin(c);
    if (session instanceof Response) return session;
    return renderOrder(c, session, c.req.param('id'), successBanner(c));
  });

  app.post('/orders/:id/collected', async (c) => {
    const begun = await beginCommand(c);
    if (begun instanceof Response) return begun;
    const { form, session } = begun;
    const orderId = c.req.param('id');
    const fields = commandFields(form);
    const revision = Number(text(form, 'revision'));
    if (!fields || !Number.isSafeInteger(revision) || revision < 1) {
      return badRequest(c, session, orderId, 'Formulário inválido. Recarregue a página.');
    }
    if (text(form, 'checked') !== '1') {
      return badRequest(c, session, orderId, 'Marque “Conferi todos os arquivos desta revisão”.');
    }
    const attempt = { idempotencyKey: fields.key, etag: fields.etag };
    try {
      await collectOrderFiles(
        deps.print,
        { orderId, revision },
        { ifMatch: fields.etag, idempotencyKey: fields.key },
      );
    } catch (error) {
      return orderCommandFailed(c, session, orderId, error, attempt);
    }
    return c.redirect(`/orders/${encodeURIComponent(orderId)}?ok=collected`, 303);
  });

  app.post('/orders/:id/printed', async (c) => {
    const begun = await beginCommand(c);
    if (begun instanceof Response) return begun;
    const { form, session } = begun;
    const orderId = c.req.param('id');
    const fields = commandFields(form);
    const revision = Number(text(form, 'revision'));
    const quoteId = text(form, 'quoteId') ?? '';
    if (!fields || !Number.isSafeInteger(revision) || revision < 1 || !UUID_RE.test(quoteId)) {
      return badRequest(c, session, orderId, 'Formulário inválido. Recarregue a página.');
    }
    const attempt = { idempotencyKey: fields.key, etag: fields.etag };
    try {
      await markOrderPrinted(
        deps.print,
        { orderId, revision, quoteId },
        { ifMatch: fields.etag, idempotencyKey: fields.key },
      );
    } catch (error) {
      return orderCommandFailed(c, session, orderId, error, attempt);
    }
    return c.redirect(`/orders/${encodeURIComponent(orderId)}?ok=printed`, 303);
  });

  const htmlUploadLimit = bodyLimit({
    maxSize: UPLOAD_BODY_MAX_BYTES,
    onError: (c) =>
      c.html(
        errorPage('Arquivo muito grande', { kind: 'error', text: 'Arquivo acima de 5 MB.' }),
        413,
      ),
  });

  app.post('/orders/:id/quotes', htmlUploadLimit, async (c) => {
    const begun = await beginCommand(c);
    if (begun instanceof Response) return begun;
    const { form, session } = begun;
    const orderId = c.req.param('id');
    const fields = commandFields(form);
    const orderRevision = Number(text(form, 'orderRevision'));
    if (!fields || !Number.isSafeInteger(orderRevision) || orderRevision < 1) {
      return badRequest(c, session, orderId, 'Formulário inválido. Recarregue a página.');
    }
    const attempt = {
      idempotencyKey: fields.key,
      etag: fields.etag,
      amountText: text(form, 'amount') ?? '',
    };
    const invalid = (message: string, status: number) =>
      renderOrder(c, session, orderId, {
        banner: { kind: 'error', text: message },
        status,
        retry: attempt,
      });
    const doc = await readDocumentForm(form, {
      amount: 'Valor do orçamento',
      file: 'arquivo do orçamento',
      fallbackName: 'orcamento',
    });
    if (!doc.ok) return invalid(doc.message, doc.status);
    try {
      await submitQuote(
        deps.print,
        { orderId, orderRevision, amountCents: doc.amountCents, file: doc.upload },
        { ifMatch: fields.etag, idempotencyKey: fields.key },
      );
    } catch (error) {
      const fileProblem =
        error instanceof UpstreamRejectedError &&
        (error.code === 'FILE_TOO_LARGE' || error.code === 'UNSUPPORTED_MEDIA_TYPE');
      if (fileProblem) return invalid(rejectionBanner(error).text, error.status);
      return orderCommandFailed(c, session, orderId, error, attempt);
    }
    return c.redirect(`/orders/${encodeURIComponent(orderId)}?ok=quote`, 303);
  });

  // ── invoices ──

  async function renderInvoices(
    c: PortalContext,
    session: PortalSession,
    competence: string,
    opts: { banner?: Banner; status?: number; retry?: ActionForm } = {},
  ): Promise<Response> {
    const currentCompetence = competenceOf(deps.session.clock());
    const base = { csrfToken: session.csrfToken, competence, currentCompetence };
    try {
      const { value, etag } = await getMonthlyClose(deps.print, competence);
      return c.html(
        invoicesPage({
          ...base,
          close: value,
          form: nextForm(etag, opts.retry, true),
          ...(opts.banner ? { banner: opts.banner } : {}),
        }),
        (opts.status ?? 200) as 200,
      );
    } catch (error) {
      if (!isUpstreamError(error)) throw error;
      if (error instanceof UpstreamRejectedError && error.status === 404) {
        // The monthly-close routes are not deployed upstream (yet).
        return c.html(
          invoicesPage({ ...base, close: null, form: null, unavailable: 'not_deployed' }),
          200,
        );
      }
      return c.html(
        invoicesPage({
          ...base,
          close: null,
          form: null,
          unavailable: 'down',
          banner: opts.banner ?? UNAVAILABLE,
        }),
        (opts.status ?? 503) as 503,
      );
    }
  }

  app.get('/invoices', async (c) => {
    const session = await sessionOrLogin(c);
    if (session instanceof Response) return session;
    const requested = c.req.query('competence');
    const competence =
      requested && isValidCompetence(requested)
        ? requested
        : previousCompetence(competenceOf(deps.session.clock()));
    return renderInvoices(c, session, competence, successBanner(c));
  });

  app.post('/invoices/:competence', htmlUploadLimit, async (c) => {
    const begun = await beginCommand(c);
    if (begun instanceof Response) return begun;
    const { form, session } = begun;
    const competence = c.req.param('competence');
    if (!isValidCompetence(competence)) return c.redirect('/invoices', 303);
    const fields = commandFields(form);
    if (!fields) {
      return renderInvoices(c, session, competence, {
        banner: { kind: 'error', text: 'Formulário inválido. Recarregue a página.' },
        status: 400,
      });
    }
    const attempt = {
      idempotencyKey: fields.key,
      etag: fields.etag,
      amountText: text(form, 'amount') ?? '',
    };
    const doc = await readDocumentForm(form, {
      amount: 'Valor total da NF',
      file: 'arquivo da NF',
      fallbackName: 'nota-fiscal',
    });
    if (!doc.ok) {
      return renderInvoices(c, session, competence, {
        banner: { kind: 'error', text: doc.message },
        status: doc.status,
        retry: attempt,
      });
    }
    try {
      await submitInvoice(
        deps.print,
        { competence, declaredTotalCents: doc.amountCents, file: doc.upload },
        { ifMatch: fields.etag, idempotencyKey: fields.key },
      );
    } catch (error) {
      if (!isUpstreamError(error)) throw error;
      return renderInvoices(c, session, competence, retryAfterFailure(error, attempt));
    }
    return c.redirect(`/invoices?competence=${competence}&ok=invoice`, 303);
  });

  return app;
}
