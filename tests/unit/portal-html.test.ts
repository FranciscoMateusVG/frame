/**
 * Server-rendered pages through the real Hono app: login form, escaping,
 * history pagination, command guards (session/Origin/CSRF), invoices against
 * v2 monthly closes, logout — plus headers. The batch home and its commands
 * are covered by portal-batch-html.test.ts.
 */
import { randomUUID } from 'node:crypto';
import { beforeEach, describe, expect, it } from 'vitest';
import type { PrintApi } from '../../src/adapters/print-api.js';
import { PrintApiMemory } from '../../src/adapters/print-api.memory.js';
import { UpstreamRejectedError } from '../../src/errors/upstream-rejected.error.js';
import { UpstreamUnavailableError } from '../../src/errors/upstream-unavailable.error.js';
import {
  createHarness,
  type Harness,
  PASSWORD,
  type PortalClient,
} from '../helpers/portal-harness.js';
import { PDF_BYTES, seedTwoFileRequest } from '../helpers/print-fixtures.js';
import { fixtureBatch, V2_ASSETS } from '../helpers/print-v2-fixture.js';

function hidden(page: string, name: string): string {
  const match = new RegExp(`name="${name}" value="([^"]*)"`).exec(page);
  if (!match?.[1]) throw new Error(`hidden field ${name} not found`);
  return match[1];
}

async function htmlLogin(browser: PortalClient, password = PASSWORD): Promise<Response> {
  const page = await (await browser.get('/login')).text();
  return browser.postForm(
    '/login',
    new URLSearchParams({ _csrf: hidden(page, '_csrf'), password }),
  );
}

describe('portal HTML', () => {
  let h: Harness;
  let browser: PortalClient;
  beforeEach(() => {
    h = createHarness();
    browser = h.client();
  });

  it('pages redirect to /login without a session (no returnTo)', async () => {
    for (const path of ['/', '/batches', `/batches/${randomUUID()}`, '/invoices']) {
      const res = await browser.get(path);
      expect(res.status, path).toBe(303);
      expect(res.headers.get('location'), path).toBe('/login');
    }
  });

  it('login form: wrong password 401 with a generic message; success sets the session and lands on the current batch', async () => {
    const page = await browser.get('/login');
    expect(page.status).toBe(200);
    expect(page.headers.get('content-security-policy')).toContain("script-src 'self'");
    expect(page.headers.get('x-frame-options')).toBe('DENY');
    const html = await page.text();
    expect(html).toContain('Senha');
    expect(html).toContain('>Entrar</button>');

    const wrong = await htmlLogin(browser, 'definitely-not-the-password');
    expect(wrong.status).toBe(401);
    const wrongHtml = await wrong.text();
    expect(wrongHtml).toContain('Senha incorreta.');
    expect(wrongHtml).not.toContain(PASSWORD);

    const ok = await htmlLogin(browser);
    expect(ok.status).toBe(303);
    expect(ok.headers.get('location')).toBe('/');
    expect(browser.cookies.has('__Host-print_session')).toBe(true);

    const home = await browser.get('/');
    const body = await home.text();
    expect(body).toContain('Lote atual');
    expect(body).toContain('Lotes anteriores');
    expect(body).toContain('Notas fiscais');
    expect(body).toContain('Sair');
    expect(body).toContain('Nenhum pedido aguardando');
    expect((await browser.get('/login')).headers.get('location')).toBe('/');
  });

  it('Referrer-Policy keeps Origin on same-origin form posts (no-referrer makes browsers send Origin: null)', async () => {
    const res = await browser.get('/login');
    expect(res.headers.get('referrer-policy')).toBe('same-origin');
  });

  it('login form without our Origin is refused', async () => {
    const page = await (await browser.get('/login')).text();
    const res = await browser.postForm(
      '/login',
      new URLSearchParams({ _csrf: hidden(page, '_csrf'), password: PASSWORD }),
      { origin: 'https://evil.test' },
    );
    expect(res.status).toBe(403);
    expect(browser.cookies.has('__Host-print_session')).toBe(false);
  });

  it('escapes untrusted request text on the batch home', async () => {
    seedTwoFileRequest(h.api, '<script>alert(1)</script>');
    await htmlLogin(browser);
    const home = await (await browser.get('/')).text();
    expect(home).not.toContain('<script>alert(1)</script>');
    expect(home).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
  });

  it('history paginates with Anterior/Próxima', async () => {
    const base = fixtureBatch('received');
    for (let i = 0; i < 21; i++) {
      const id = `00000000-0000-4000-8000-${String(1000 + i).padStart(12, '0')}`;
      h.api.seedBatch({ ...base, id, reference: `LOT-${1000 + i}` }, V2_ASSETS);
    }
    await htmlLogin(browser);
    const first = await (await browser.get('/batches')).text();
    expect(first.match(/data-ttp="history-batch"/g)).toHaveLength(20);
    const next = /href="(\/batches\?cursor=[^"]+)">Próxima/
      .exec(first)?.[1]
      ?.replaceAll('&amp;', '&');
    expect(next).toBeDefined();
    const second = await (await browser.get(next ?? '')).text();
    expect(second.match(/data-ttp="history-batch"/g)).toHaveLength(1);
    expect(second).toMatch(/href="\/batches(\?back=)?"[^>]*>Anterior/);
    expect((await browser.get('/batches?cursor=bogus')).headers.get('location')).toBe('/batches');
  });

  it('distinguishes an empty history from an unavailable upstream', async () => {
    const down = createHarness({
      printApi: new Proxy({} as PrintApi, {
        get: () => async () => {
          throw new UpstreamUnavailableError('timeout');
        },
      }),
    });
    const b = down.client();
    await htmlLogin(b);
    const res = await b.get('/batches');
    expect(res.status).toBe(503);
    const html = await res.text();
    expect(html).toContain('data-state="unavailable"');
    expect(html).not.toContain('Nenhum lote anterior');
    expect((await b.get(`/batches/${randomUUID()}`)).status).toBe(503);
  });

  it('expired session during a command redirects to login, never a false success', async () => {
    const request = seedTwoFileRequest(h.api);
    await htmlLogin(browser);
    const page = await (await browser.get('/')).text();
    const batchId = /data-batch-id="([^"]+)"/.exec(page)?.[1] ?? '';
    h.clock.now = new Date(h.clock.now.getTime() + 31 * 60 * 1000);
    const res = await browser.postForm(
      `/batches/${batchId}/collected`,
      new URLSearchParams({
        _csrf: hidden(page, '_csrf'),
        idempotencyKey: hidden(page, 'idempotencyKey'),
        etag: hidden(page, 'etag').replaceAll('&quot;', '"'),
        checked: '1',
        confirmed: '1',
      }),
    );
    expect(res.status).toBe(303);
    expect(res.headers.get('location')).toBe('/login');
    const batch = (await h.api.getBatch(batchId)).value;
    expect(batch.status).toBe('open');
    expect(batch.items[0]?.orderId).toBe(request.orderId);
  });

  it('a command form from another origin or with a bad CSRF token is refused', async () => {
    seedTwoFileRequest(h.api);
    await htmlLogin(browser);
    const page = await (await browser.get('/')).text();
    const batchId = /data-batch-id="([^"]+)"/.exec(page)?.[1] ?? '';
    const form = () =>
      new URLSearchParams({
        _csrf: hidden(page, '_csrf'),
        idempotencyKey: hidden(page, 'idempotencyKey'),
        etag: hidden(page, 'etag').replaceAll('&quot;', '"'),
        checked: '1',
        confirmed: '1',
      });
    const foreign = await browser.postForm(`/batches/${batchId}/collected`, form(), {
      origin: 'https://evil.test',
    });
    expect(foreign.status).toBe(403);
    const badCsrf = form();
    badCsrf.set('_csrf', 'nope');
    expect((await browser.postForm(`/batches/${batchId}/collected`, badCsrf)).status).toBe(403);
    const badKey = form();
    badKey.set('idempotencyKey', 'not-a-uuid');
    expect((await browser.postForm(`/batches/${batchId}/collected`, badKey)).status).toBe(400);
    expect((await h.api.getBatch(batchId)).value.status).toBe('open');
  });

  it('invoices: previous competence by default, period rule for the current month, NF form', async () => {
    await htmlLogin(browser);
    const current = await (await browser.get('/invoices?competence=2026-10')).text();
    expect(current).toContain('Competência');
    expect(current).toContain('31/10/2026');
    expect(current).not.toContain('Enviar NF');

    const def = await (await browser.get('/invoices')).text();
    expect(def).toContain('value="2026-09"');
    expect(def).toContain('Total calculado');
    expect(def).toContain('Nenhum lote impresso nesta competência.');
  });

  it('invoices: items, NF submission with divergence, rejection and resubmission', async () => {
    h.clock.now = new Date('2026-09-15T15:00:00.000Z');
    seedTwoFileRequest(h.api);
    const open = await h.api.getOpenBatch();
    const batchId = open?.value.id ?? '';
    await h.api.markCollected(batchId, { ifMatch: `"${batchId}:1"`, idempotencyKey: randomUUID() });
    const q = await h.api.submitQuote(
      batchId,
      { amountCents: 56_900, file: { filename: 'q.pdf', bytes: PDF_BYTES } },
      { ifMatch: `"${batchId}:2"`, idempotencyKey: randomUUID() },
    );
    const approved = h.api.approveQuote(batchId);
    await h.api.markPrinted(
      batchId,
      { quoteId: q.value.currentQuote?.id ?? '' },
      { ifMatch: `"${batchId}:${approved.version}"`, idempotencyKey: randomUUID() },
    );
    h.api.seedLegacyCharge({
      reference: 'IMP-0301',
      amountCents: 1_000,
      printedAt: '2026-09-10T12:00:00.000Z',
    });
    h.clock.now = new Date('2026-10-08T12:00:00.000Z');
    await htmlLogin(browser);

    const page = await (await browser.get('/invoices?competence=2026-09')).text();
    // One charge per batch (linking to its detail) plus the historical individual order.
    expect(page).toContain(`<a href="/batches/${batchId}">${approved.reference}</a>`);
    expect(page).toContain('IMP-0301 <span class="meta">(pedido individual)</span>');
    expect(page).toContain('R$ 569,00');
    expect(page).toContain('R$ 579,00');
    expect(page).toContain('Valor total da NF');
    expect(page).toContain('Arquivo da NF');
    expect(page).toContain('Enviar NF');

    const submit = (html: string, amount: string) => {
      const form = new FormData();
      form.set('_csrf', hidden(html, '_csrf'));
      form.set('idempotencyKey', hidden(html, 'idempotencyKey'));
      form.set('etag', hidden(html, 'etag').replaceAll('&quot;', '"'));
      form.set('amount', amount);
      form.set('file', new File([PDF_BYTES], 'nf.pdf', { type: 'application/pdf' }));
      return browser.postForm('/invoices/2026-09', form);
    };
    const sent = await submit(page, '570,00');
    expect(sent.status).toBe(303);
    const waiting = await (await browser.get(sent.headers.get('location') ?? '')).text();
    expect(waiting).toContain('NF enviada. Aguardando conferência.');
    expect(waiting).toContain('diverge do total calculado');
    expect(waiting).toContain('Baixar NF');
    expect(waiting).not.toContain('>Enviar NF</button>');

    h.api.decideInvoice('2026-09', 'rejected', 'Valor diferente do calculado');
    const rejected = await (await browser.get('/invoices?competence=2026-09')).text();
    expect(rejected).toContain('NF rejeitada. Motivo: Valor diferente do calculado');
    expect(rejected).toContain('Enviar nova NF');
    expect((await submit(rejected, '579,00')).status).toBe(303);
    expect((await h.api.getMonthlyClose('2026-09')).value.declaredTotalCents).toBe(57_900);
  });

  it('invoices: an upstream without monthly-close routes shows "Notas fiscais ainda indisponíveis"', async () => {
    const api = new PrintApiMemory();
    const missing = new Proxy(api, {
      get(target, prop, receiver) {
        if (prop === 'getMonthlyClose') {
          return async () => {
            throw new UpstreamRejectedError(404, 'NOT_FOUND', 'Recurso não encontrado.', 'r');
          };
        }
        const value = Reflect.get(target, prop, receiver);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    });
    const hm = createHarness({ printApi: missing });
    const b = hm.client();
    await htmlLogin(b);
    const res = await b.get('/invoices');
    expect(res.status).toBe(200);
    expect(await res.text()).toContain('Notas fiscais ainda indisponíveis.');
  });

  it('Sair revokes the session; afterwards pages need the password again', async () => {
    await htmlLogin(browser);
    const page = await (await browser.get('/')).text();
    const out = await browser.postForm(
      '/logout',
      new URLSearchParams({ _csrf: hidden(page, '_csrf') }),
    );
    expect(out.status).toBe(303);
    expect(out.headers.get('location')).toBe('/login');
    expect((await browser.get('/')).headers.get('location')).toBe('/login');
  });

  it('serves assets and health probes; HTML never contains the service token or password', async () => {
    expect((await browser.get('/healthz')).status).toBe(200);
    expect((await browser.get('/readyz')).status).toBe(200);
    const css = await browser.get('/assets/portal.css');
    expect(css.headers.get('content-type')).toContain('text/css');
    const js = await browser.get('/assets/portal.js');
    expect(js.headers.get('content-type')).toContain('javascript');
    await htmlLogin(browser);
    const html = await (await browser.get('/')).text();
    expect(html).not.toContain(PASSWORD);
    expect(html).not.toMatch(/Bearer/i);
  });
});
