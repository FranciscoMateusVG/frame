/**
 * Server-rendered journey (spec §7) through the real Hono app: login form,
 * order list/detail, the three supplier commands as HTML forms, retries
 * after an ambiguous failure, invoices, logout — plus escaping and headers.
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
import { PDF_BYTES, seedTwoFileOrder } from '../helpers/print-fixtures.js';

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
    for (const path of ['/', '/orders', `/orders/${randomUUID()}`, '/invoices']) {
      const res = await browser.get(path);
      expect(res.status, path).toBeGreaterThanOrEqual(302);
      expect(res.headers.get('location'), path).toMatch(/^\/(login|orders)$/);
    }
    expect((await browser.get('/orders')).headers.get('location')).toBe('/login');
  });

  it('login form: wrong password 401 with a generic message; success sets the session and lands on Pedidos', async () => {
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
    expect(ok.headers.get('location')).toBe('/orders');
    expect(browser.cookies.has('__Host-print_session')).toBe(true);

    const orders = await browser.get('/orders');
    const body = await orders.text();
    expect(body).toContain('Pedidos');
    expect(body).toContain('Notas fiscais');
    expect(body).toContain('Sair');
    expect(body).toContain('Nenhum pedido');
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

  it('lists orders, escapes untrusted text, paginates with Anterior/Próxima', async () => {
    seedTwoFileOrder(h.api, '<script>alert(1)</script>');
    for (let i = 0; i < 21; i++) seedTwoFileOrder(h.api, `Pedido ${i}`);
    await htmlLogin(browser);

    const first = await (await browser.get('/orders')).text();
    expect(first).not.toContain('<script>alert(1)</script>');
    expect(first).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
    expect(first.match(/Ver pedido/g)).toHaveLength(20);
    const next = /href="(\/orders\?cursor=[^"]+)">Próxima/
      .exec(first)?.[1]
      ?.replaceAll('&amp;', '&');
    expect(next).toBeDefined();

    const second = await (await browser.get(next ?? '')).text();
    expect(second.match(/Ver pedido/g)).toHaveLength(2);
    expect(second).toMatch(
      /href="\/orders(\?back=)?"[^>]*>Anterior|href="\/orders\?back=[^"]*">Anterior/,
    );
  });

  it('distinguishes "Nenhum pedido" from an unavailable upstream', async () => {
    const down = createHarness({
      printApi: new Proxy({} as PrintApi, {
        get: () => async () => {
          throw new UpstreamUnavailableError('timeout');
        },
      }),
    });
    const b = down.client();
    await htmlLogin(b);
    const res = await b.get('/orders');
    expect(res.status).toBe(503);
    const html = await res.text();
    expect(html).toContain('data-state="unavailable"');
    expect(html).not.toContain('Nenhum pedido');
  });

  it('order detail shows jobs, downloads and the collect form; collecting redirects with confirmation', async () => {
    const order = seedTwoFileOrder(h.api);
    await htmlLogin(browser);
    const page = await (await browser.get(`/orders/${order.id}`)).text();
    for (const text of [
      order.reference,
      'Apostila de Matemática',
      'Frente e verso, grampeado',
      'Só frente, colorido',
      'Baixar arquivo',
      'Conferi todos os arquivos desta revisão',
      'Arquivos retirados',
      'Confirmar retirada',
      'Voltar',
    ]) {
      expect(page).toContain(text);
    }
    expect(page).toContain(`/api/print/v1/orders/${order.id}/files/${order.jobs[0]?.file.id}`);

    const form = new URLSearchParams({
      _csrf: hidden(page, '_csrf'),
      idempotencyKey: hidden(page, 'idempotencyKey'),
      etag: hidden(page, 'etag').replaceAll('&quot;', '"'),
      revision: '1',
    });
    const unchecked = await browser.postForm(`/orders/${order.id}/collected`, form);
    expect(unchecked.status).toBe(400);
    expect(await unchecked.text()).toContain('Conferi todos os arquivos');

    form.set('checked', '1');
    const done = await browser.postForm(`/orders/${order.id}/collected`, form);
    expect(done.status).toBe(303);
    expect(done.headers.get('location')).toBe(`/orders/${order.id}?ok=collected`);
    const after = await (await browser.get(done.headers.get('location') ?? '')).text();
    expect(after).toContain('Retirada confirmada.');
    expect(after).toContain('Valor do orçamento');
    expect(after).toContain('Arquivo do orçamento');
    expect(after).toContain('Enviar orçamento');

    // Double submit of the same form = same key and intent → replay, no error.
    const again = await browser.postForm(`/orders/${order.id}/collected`, form);
    expect(again.status).toBe(303);
  });

  it('quote via form converts BRL to cents; pending shows the waiting state; approval enables printing', async () => {
    const order = seedTwoFileOrder(h.api);
    await h.api.markCollected(
      order.id,
      { revision: 1 },
      { ifMatch: `"${order.id}:1"`, idempotencyKey: randomUUID() },
    );
    await htmlLogin(browser);
    const page = await (await browser.get(`/orders/${order.id}`)).text();
    const form = () => {
      const f = new FormData();
      f.set('_csrf', hidden(page, '_csrf'));
      f.set('idempotencyKey', hidden(page, 'idempotencyKey'));
      f.set('etag', hidden(page, 'etag').replaceAll('&quot;', '"'));
      f.set('orderRevision', '1');
      f.set('file', new File([PDF_BYTES], 'orcamento.pdf', { type: 'application/pdf' }));
      return f;
    };

    const badAmount = form();
    badAmount.set('amount', '12.34');
    const bad = await browser.postForm(`/orders/${order.id}/quotes`, badAmount);
    expect(bad.status).toBe(400);
    const badHtml = await bad.text();
    expect(badHtml).toContain('Valor do orçamento inválido');
    expect(badHtml).toContain('value="12.34"');

    const good = form();
    good.set('amount', 'R$ 1.234,56');
    const sent = await browser.postForm(`/orders/${order.id}/quotes`, good);
    expect(sent.status).toBe(303);
    const stored = await h.api.getOrder(order.id);
    expect(stored.value.currentQuote?.amountCents).toBe(123_456);

    const waiting = await (await browser.get(`/orders/${order.id}`)).text();
    expect(waiting).toContain('Aguardando aprovação do Financeiro');
    expect(waiting).toContain('Baixar orçamento');
    expect(waiting).not.toContain('Aprovar');
    expect(waiting).not.toContain('Marcar como impresso');

    h.api.approveQuote(order.id);
    const approved = await (await browser.get(`/orders/${order.id}`)).text();
    expect(approved).toContain('Orçamento aprovado');
    expect(approved).toContain('Marcar como impresso');
    expect(approved).toContain('Confirmar impressão');
    const printForm = new URLSearchParams({
      _csrf: hidden(approved, '_csrf'),
      idempotencyKey: hidden(approved, 'idempotencyKey'),
      etag: hidden(approved, 'etag').replaceAll('&quot;', '"'),
      revision: '1',
      quoteId: hidden(approved, 'quoteId'),
    });
    const printed = await browser.postForm(`/orders/${order.id}/printed`, printForm);
    expect(printed.status).toBe(303);
    expect((await h.api.getOrder(order.id)).value.status).toBe('printed');
  });

  it('rejected quote shows the reason and "Enviar novo orçamento"', async () => {
    const order = seedTwoFileOrder(h.api);
    await h.api.markCollected(
      order.id,
      { revision: 1 },
      { ifMatch: `"${order.id}:1"`, idempotencyKey: randomUUID() },
    );
    await h.api.submitQuote(
      order.id,
      { amountCents: 100, orderRevision: 1, file: { filename: 'q.pdf', bytes: PDF_BYTES } },
      { ifMatch: `"${order.id}:2"`, idempotencyKey: randomUUID() },
    );
    h.api.rejectQuote(order.id, 'Faltou o frete <b>combinado</b>');
    await htmlLogin(browser);
    const page = await (await browser.get(`/orders/${order.id}`)).text();
    expect(page).toContain('Orçamento rejeitado');
    expect(page).toContain('Faltou o frete &lt;b&gt;combinado&lt;/b&gt;');
    expect(page).toContain('Enviar novo orçamento');
  });

  it('stale form → 412 "Pedido atualizado; confira novamente" with a fresh key', async () => {
    const order = seedTwoFileOrder(h.api);
    await htmlLogin(browser);
    const page = await (await browser.get(`/orders/${order.id}`)).text();
    const key = hidden(page, 'idempotencyKey');
    const form = new URLSearchParams({
      _csrf: hidden(page, '_csrf'),
      idempotencyKey: key,
      etag: `"${order.id}:0"`,
      revision: '1',
      checked: '1',
    });
    const res = await browser.postForm(`/orders/${order.id}/collected`, form);
    expect(res.status).toBe(412);
    const html = await res.text();
    expect(html).toContain('Pedido atualizado; confira novamente.');
    expect(hidden(html, 'idempotencyKey')).not.toBe(key);
  });

  it('ambiguous failure (503) re-renders with the SAME key so repeating cannot double-apply', async () => {
    const real = new PrintApiMemory({ clock: () => new Date('2026-10-08T12:00:00Z') });
    let failNext = false;
    const flaky = new Proxy(real, {
      get(target, prop, receiver) {
        const value = Reflect.get(target, prop, receiver);
        if (prop === 'markCollected') {
          return async (...args: Parameters<PrintApiMemory['markCollected']>) => {
            if (failNext) {
              failNext = false;
              throw new UpstreamUnavailableError('timeout');
            }
            return target.markCollected(...args);
          };
        }
        return typeof value === 'function' ? value.bind(target) : value;
      },
    });
    const hf = createHarness({ printApi: flaky });
    const order = seedTwoFileOrder(real);
    const b = hf.client();
    await htmlLogin(b);
    const page = await (await b.get(`/orders/${order.id}`)).text();
    const key = hidden(page, 'idempotencyKey');
    const form = new URLSearchParams({
      _csrf: hidden(page, '_csrf'),
      idempotencyKey: key,
      etag: hidden(page, 'etag').replaceAll('&quot;', '"'),
      revision: '1',
      checked: '1',
    });
    failNext = true;
    const res = await b.postForm(`/orders/${order.id}/collected`, form);
    expect(res.status).toBe(503);
    const html = await res.text();
    expect(html).toContain('Serviço indisponível');
    expect(html).toContain('Consultar novamente');
    expect(hidden(html, 'idempotencyKey')).toBe(key);
    expect((await real.getOrder(order.id)).value.status).toBe('ready');

    const retry = await b.postForm(`/orders/${order.id}/collected`, form);
    expect(retry.status).toBe(303);
    expect((await real.getOrder(order.id)).value.status).toBe('files_collected');
  });

  it('expired session during a command redirects to login, never a false success', async () => {
    const order = seedTwoFileOrder(h.api);
    await htmlLogin(browser);
    const page = await (await browser.get(`/orders/${order.id}`)).text();
    h.clock.now = new Date(h.clock.now.getTime() + 31 * 60 * 1000);
    const res = await browser.postForm(
      `/orders/${order.id}/collected`,
      new URLSearchParams({
        _csrf: hidden(page, '_csrf'),
        idempotencyKey: hidden(page, 'idempotencyKey'),
        etag: hidden(page, 'etag').replaceAll('&quot;', '"'),
        revision: '1',
        checked: '1',
      }),
    );
    expect(res.status).toBe(303);
    expect(res.headers.get('location')).toBe('/login');
    expect((await h.api.getOrder(order.id)).value.status).toBe('ready');
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
    expect(def).toContain('Nenhum pedido impresso nesta competência.');
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
    const page = await (await browser.get('/orders')).text();
    const out = await browser.postForm(
      '/logout',
      new URLSearchParams({ _csrf: hidden(page, '_csrf') }),
    );
    expect(out.status).toBe(303);
    expect(out.headers.get('location')).toBe('/login');
    expect((await browser.get('/orders')).headers.get('location')).toBe('/login');
  });

  it('serves assets and health probes; HTML never contains the service token or password', async () => {
    expect((await browser.get('/healthz')).status).toBe(200);
    expect((await browser.get('/readyz')).status).toBe(200);
    const css = await browser.get('/assets/portal.css');
    expect(css.headers.get('content-type')).toContain('text/css');
    const js = await browser.get('/assets/portal.js');
    expect(js.headers.get('content-type')).toContain('javascript');
    await htmlLogin(browser);
    const html = await (await browser.get('/orders')).text();
    expect(html).not.toContain(PASSWORD);
    expect(html).not.toMatch(/Bearer/i);
  });
});
