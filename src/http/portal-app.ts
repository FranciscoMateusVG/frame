/**
 * The print-shop portal as one Hono app: security headers, request ids,
 * health probes, static assets, the JSON API and the HTML pages. Pure
 * assembly — every dependency is passed in (see server.ts for the real
 * composition and tests/helpers for the fake one).
 */
import { Hono } from 'hono';
import { portalApiRoutes } from './portal-api-routes.js';
import { PORTAL_CSS, PORTAL_JS } from './portal-assets.js';
import { portalHtmlRoutes } from './portal-html-routes.js';
import {
  drainUnreadBody,
  errorToJson,
  jsonError,
  limitBody,
  type PortalContext,
  type PortalDeps,
  type PortalEnv,
} from './portal-http.js';
import { errorPage } from './portal-views.js';

// Replaced by tsup at build time; direct source execution has no revision.
declare const __BUILD_SHA__: string;
const BUILD_REVISION = typeof __BUILD_SHA__ === 'undefined' ? 'unknown' : __BUILD_SHA__;

/** Every non-upload body (login, JSON commands, forms) is tiny. */
const SMALL_BODY_MAX_BYTES = 64 * 1024;

/** Upload routes carry their own 5 MiB + 512 KiB limit. */
const UPLOAD_ROUTE =
  /^\/(api\/print\/v2\/batches\/[^/]+\/quotes|api\/print\/v2\/monthly-closes\/[^/]+\/invoice|batches\/[^/]+\/quotes|invoices\/[^/]+)$/;

const smallBodyLimit = limitBody(SMALL_BODY_MAX_BYTES, tooLarge);

function tooLarge(c: PortalContext): Response | Promise<Response> {
  return c.req.path.startsWith('/api/')
    ? jsonError(c, 413, 'PAYLOAD_TOO_LARGE', 'Requisição grande demais.')
    : c.html(
        errorPage('Requisição grande demais', { kind: 'error', text: 'Requisição grande demais.' }),
        413,
      );
}

const HTML_CSP =
  "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";

export function createPortalApp(deps: PortalDeps): Hono<PortalEnv> {
  const app = new Hono<PortalEnv>();

  // Outermost: once a response is ready, drain any request body the
  // handlers left unread (bounded), so early 4xx answers reach the client.
  app.use('*', async (c, next) => {
    await next();
    await drainUnreadBody(c);
  });

  app.use('*', async (c, next) => {
    c.set('requestId', deps.requestId());
    await next();
    c.header('X-Request-Id', c.get('requestId'));
    c.header('X-Content-Type-Options', 'nosniff');
    // same-origin, not no-referrer: with no-referrer browsers send `Origin: null`
    // on form POSTs, which the exact-Origin CSRF check (rightly) refuses.
    c.header('Referrer-Policy', 'same-origin');
    c.header('X-Frame-Options', 'DENY');
    if (!c.res.headers.has('Cache-Control')) c.header('Cache-Control', 'no-store');
    if ((c.res.headers.get('Content-Type') ?? '').startsWith('text/html')) {
      c.header('Content-Security-Policy', HTML_CSP);
    }
  });

  app.onError((error, c) => {
    if (c.req.path.startsWith('/api/')) return errorToJson(c, error, deps.logger);
    deps.logger.error('portal.unhandled_error', {
      requestId: c.get('requestId'),
      errorName: error instanceof Error ? error.name : typeof error,
    });
    return c.html(
      errorPage('Erro', { kind: 'error', text: 'Erro interno. Tente novamente.' }),
      500,
    );
  });

  // Cap request bodies BEFORE any handler buffers them (Content-Length or
  // chunked); upload routes are capped by their own, larger limit.
  app.use('*', async (c, next) => {
    if (c.req.method === 'GET' || c.req.method === 'HEAD' || UPLOAD_ROUTE.test(c.req.path)) {
      return next();
    }
    return smallBodyLimit(c, next);
  });

  app.get('/version', (c) => c.json({ revision: BUILD_REVISION }));
  app.get('/healthz', (c) => c.json({ status: 'ok' }));
  app.get('/readyz', (c) => c.json({ status: 'ok' }));

  app.get('/assets/portal.css', (c) =>
    c.body(PORTAL_CSS, 200, {
      'Content-Type': 'text/css; charset=UTF-8',
      'Cache-Control': 'public, max-age=300',
    }),
  );
  app.get('/assets/portal.js', (c) =>
    c.body(PORTAL_JS, 200, {
      'Content-Type': 'text/javascript; charset=UTF-8',
      'Cache-Control': 'public, max-age=300',
    }),
  );

  app.route('/', portalApiRoutes(deps));
  app.route('/', portalHtmlRoutes(deps));

  app.notFound((c) =>
    c.req.path.startsWith('/api/')
      ? jsonError(c, 404, 'NOT_FOUND', 'Recurso não encontrado.')
      : c.html(
          errorPage('Página não encontrada', { kind: 'error', text: 'Página não encontrada.' }),
          404,
        ),
  );

  return app;
}
