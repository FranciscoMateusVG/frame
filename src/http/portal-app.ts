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
import { errorToJson, jsonError, type PortalDeps, type PortalEnv } from './portal-http.js';
import { errorPage } from './portal-views.js';

const HTML_CSP =
  "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";

export function createPortalApp(deps: PortalDeps): Hono<PortalEnv> {
  const app = new Hono<PortalEnv>();

  app.use('*', async (c, next) => {
    c.set('requestId', deps.requestId());
    await next();
    c.header('X-Request-Id', c.get('requestId'));
    c.header('X-Content-Type-Options', 'nosniff');
    c.header('Referrer-Policy', 'no-referrer');
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
