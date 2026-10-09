/**
 * Task 1 acceptance — the single current-batch home screen, through the
 * real Hono app (login form, cookies, Origin, CSRF) over the memory fake
 * seeded with the FROZEN v2 fixture: per-file cards, legacy residual
 * instructions, the three batch commands with confirmation/If-Match/
 * Idempotency-Key, state-driven actions, history and the `data-ttp` markers.
 */
import { createHash } from 'node:crypto';
import { beforeEach, describe, expect, it } from 'vitest';
import { PrintApiMemory } from '../../src/adapters/print-api.memory.js';
import type { Batch, BatchStatus } from '../../src/domain/print-batch.js';
import { UpstreamUnavailableError } from '../../src/errors/upstream-unavailable.error.js';
import { type HtmlNode, parseHtml } from '../helpers/html-markers.js';
import {
  createHarness,
  type Harness,
  PASSWORD,
  type PortalClient,
} from '../helpers/portal-harness.js';
import { PDF_BYTES, PNG_BYTES } from '../helpers/print-fixtures.js';
import { fixtureBatch, V2_ASSETS, V2_FIXTURE } from '../helpers/print-v2-fixture.js';

function hidden(page: string, name: string): string {
  const match = new RegExp(`name="${name}" value="([^"]*)"`).exec(page);
  if (!match?.[1]) throw new Error(`hidden field ${name} not found`);
  return match[1].replaceAll('&quot;', '"');
}

async function htmlLogin(browser: PortalClient): Promise<Response> {
  const page = await (await browser.get('/login')).text();
  return browser.postForm(
    '/login',
    new URLSearchParams({ _csrf: hidden(page, '_csrf'), password: PASSWORD }),
  );
}

async function home(browser: PortalClient): Promise<{ html: string; doc: HtmlNode }> {
  const res = await browser.get('/');
  expect(res.status).toBe(200);
  const html = await res.text();
  return { html, doc: parseHtml(html) };
}

/** Hidden command fields of the page plus explicit confirmation. */
function command(page: string, extra: Record<string, string> = {}): URLSearchParams {
  return new URLSearchParams({
    _csrf: hidden(page, '_csrf'),
    idempotencyKey: hidden(page, 'idempotencyKey'),
    etag: hidden(page, 'etag'),
    confirmed: '1',
    ...extra,
  });
}

function quoteForm(page: string, file: File, amount = '459,00'): FormData {
  const form = new FormData();
  for (const [k, v] of command(page)) form.set(k, v);
  form.set('amount', amount);
  form.set('file', file);
  return form;
}

const sha256 = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');

/** Every marker the shared HTTP smoke checks, against the expected fixture batch. */
function expectBatchMarkers(doc: HtmlNode, batch: Batch): void {
  const root = doc.one('batch');
  expect(root.visible()).toBe(true);
  expect(root.attrs['data-batch-id']).toBe(batch.id);
  expect(root.attrs['data-status']).toBe(batch.status);
  expect(doc.marked('empty')).toEqual([]);
  expect(root.one('batch-reference').text()).toBe(batch.reference);
  const items = root.marked('item');
  expect(doc.marked('item')).toEqual(items);
  expect(items.map((i) => i.attrs['data-order-id'])).toEqual(batch.items.map((i) => i.orderId));
  const allCards: HtmlNode[] = [];
  batch.items.forEach((item, n) => {
    const node = items[n] as HtmlNode;
    expect(node.one('item-reference').text()).toBe(item.reference);
    const general = item.generalInstructions;
    if (general) {
      expect(node.one('general-instructions').text()).toBe(general.text.split(/\s+/).join(' '));
    } else {
      expect(node.marked('general-instructions')).toEqual([]);
    }
    if (item.previouslyCancelledIn) {
      expect(node.one('previously-cancelled').text()).toContain(item.previouslyCancelledIn);
    } else {
      expect(node.marked('previously-cancelled')).toEqual([]);
    }
    const expected = [
      ...item.jobs.map((j) => ({ file: j.file, job: j })),
      ...(general?.files ?? []).map((file) => ({ file, job: null })),
    ];
    const cards = node.marked('file');
    allCards.push(...cards);
    expect(cards.map((c) => c.attrs['data-file-id'])).toEqual(expected.map((e) => e.file.id));
    expected.forEach(({ file, job }, k) => {
      const card = cards[k] as HtmlNode;
      expect(card.visible()).toBe(true);
      expect(card.one('file-name').text()).toBe(file.name);
      const size = card.one('file-size');
      expect(size.attrs['data-bytes']).toBe(String(file.bytes));
      expect(size.text()).not.toBe('');
      if (job) {
        expect(card.one('copies').text()).toBe(String(job.copies));
        expect(card.one('instructions').text()).toBe(job.instructions);
      } else {
        expect(card.marked('copies')).toEqual([]);
        expect(card.marked('instructions')).toEqual([]);
      }
      const link = card.one('download');
      expect(link.tag).toBe('a');
      expect(link.text()).toBe('Baixar arquivo');
      expect(link.attrs.href).toBe(
        `/api/print/v2/batches/${batch.id}/orders/${item.orderId}/files/${file.id}`,
      );
    });
  });
  expect(doc.marked('file')).toEqual(allCards);
  expect(doc.marked('download')).toHaveLength(allCards.length);
}

const ACTIONS: Partial<Record<BatchStatus, [string, string]>> = {
  open: ['collect', 'Retirei os arquivos'],
  files_collected: ['upload-quote', 'Enviar orçamento'],
  quote_rejected: ['upload-quote', 'Enviar orçamento'],
  quote_approved: ['mark-printed', 'Marcar como impresso'],
};
const WAITING: Partial<Record<BatchStatus, string>> = {
  quote_pending: 'Aguardando aprovação do Financeiro',
  printed: 'Aguardando recebimento',
};

describe('portal HTML — current batch home', () => {
  let h: Harness;
  let browser: PortalClient;
  beforeEach(() => {
    h = createHarness();
    browser = h.client();
  });

  it('login lands on the batch home; the old order screens are gone', async () => {
    expect((await browser.get('/')).headers.get('location')).toBe('/login');
    const login = await htmlLogin(browser);
    expect(login.status).toBe(303);
    expect(login.headers.get('location')).toBe('/');
    for (const path of ['/orders', '/orders/00000000-0000-4000-8000-000000000001']) {
      expect((await browser.get(path)).status, path).toBe(404);
    }
  });

  it('shows the open batch: header, progress, every item and file card in contract order', async () => {
    const batch = fixtureBatch('open');
    h.api.seedBatch(batch, V2_ASSETS);
    await htmlLogin(browser);
    const { doc } = await home(browser);
    expectBatchMarkers(doc, batch);
    const header = doc.one('batch').text();
    expect(header).toContain('LOT-0001');
    expect(header).toContain('1 solicitação');
    expect(header).toContain('36 cópias'); // 24 + 12; residual files carry no copies
    const progress = doc.one('progress');
    expect(progress.text()).toBe(
      'Pronto Arquivos retirados Orçamento enviado Orçamento aprovado Impresso',
    );
    const item = doc.one('item');
    expect(item.text()).toContain('IMP-0001 · Materiais sintéticos da turma');
    // Unpaired legacy file: never a guessed association.
    const residual = item.marked('file')[2] as HtmlNode;
    expect(residual.text()).toContain('Sem vínculo seguro — consulte instruções gerais');
  });

  it('each card downloads its exact bytes with the session only', async () => {
    const batch = fixtureBatch('open');
    h.api.seedBatch(batch, V2_ASSETS);
    await htmlLogin(browser);
    const { doc } = await home(browser);
    for (const link of doc.marked('download')) {
      const href = link.attrs.href as string;
      const res = await browser.get(href);
      expect(res.status).toBe(200);
      expect(res.headers.get('content-type')).toBe('application/pdf');
      expect(res.headers.get('content-disposition')).toMatch(/^attachment;/);
      const bytes = new Uint8Array(await res.arrayBuffer());
      const id = href.split('/').pop() as string;
      expect(sha256(bytes)).toBe(sha256(V2_ASSETS.get(id) as Uint8Array));
      expect((await h.client().get(href)).status).toBe(401);
    }
  });

  it('re-batched after cancellation: warning on the returning item only, residual block kept per request', async () => {
    const batch = structuredClone(V2_FIXTURE.rebatchedBatch.batch);
    h.api.seedBatch(batch, V2_ASSETS);
    await htmlLogin(browser);
    const { doc } = await home(browser);
    expectBatchMarkers(doc, batch);
    const [first, second] = doc.marked('item') as [HtmlNode, HtmlNode];
    expect(first.one('previously-cancelled').text()).toBe(
      'Este item esteve no lote LOT-0001, cancelado — confira antes de imprimir',
    );
    expect(second.marked('previously-cancelled')).toEqual([]);
    expect(second.marked('general-instructions')).toEqual([]);
    expect(doc.one('batch').text()).toContain('2 solicitações');
  });

  it('renders only the action allowed in each state, or the waiting message', async () => {
    for (const status of [
      'open',
      'files_collected',
      'quote_pending',
      'quote_rejected',
      'quote_approved',
      'printed',
    ] as const) {
      const hs = createHarness();
      const b = hs.client();
      const batch = fixtureBatch(status);
      hs.api.seedBatch(batch, V2_ASSETS);
      await htmlLogin(b);
      const { doc } = await home(b);
      expectBatchMarkers(doc, batch);
      const actions = doc.marked('action');
      const expected = ACTIONS[status];
      if (expected) {
        expect(actions, status).toHaveLength(1);
        const action = actions[0] as HtmlNode;
        expect(action.tag).toBe('button');
        expect(action.attrs.type ?? 'submit').toBe('submit');
        expect(action.attrs['data-action']).toBe(expected[0]);
        expect(action.text()).toBe(expected[1]);
        expect(doc.marked('status-message'), status).toEqual([]);
      } else {
        expect(actions, status).toEqual([]);
        expect(doc.one('status-message').text()).toBe(WAITING[status]);
      }
    }
  });

  it('the rejected quote shows its reason above the new quote form', async () => {
    h.api.seedBatch(fixtureBatch('quote_rejected'), V2_ASSETS);
    await htmlLogin(browser);
    const { html } = await home(browser);
    expect(html).toContain('Orçamento rejeitado. Motivo: Corrigir quantidade total');
  });

  it('empty state when there is no current batch', async () => {
    h.api.seedBatch(fixtureBatch('received'), V2_ASSETS);
    await htmlLogin(browser);
    const { doc } = await home(browser);
    expect(doc.one('empty').text()).toBe('Nenhum pedido aguardando');
    for (const marker of ['batch', 'item', 'file', 'action']) {
      expect(doc.marked(marker), marker).toEqual([]);
    }
  });

  it('an active (collected…printed) batch is the home even though /batches/open is null', async () => {
    const batch = fixtureBatch('quote_approved');
    h.api.seedBatch(fixtureBatch('cancelled'), V2_ASSETS);
    h.api.seedBatch({ ...batch, id: '00000000-0000-4000-8000-000000000065' }, V2_ASSETS);
    await htmlLogin(browser);
    const { doc } = await home(browser);
    expect(doc.one('batch').attrs['data-status']).toBe('quote_approved');
    expect(doc.one('batch').attrs['data-batch-id']).toBe('00000000-0000-4000-8000-000000000065');
  });

  it('"Retirei os arquivos": blocked without the checkbox; with it → files_collected', async () => {
    const batch = fixtureBatch('open');
    h.api.seedBatch(batch, V2_ASSETS);
    await htmlLogin(browser);
    const { html } = await home(browser);
    expect(html).toContain('Conferi todos os arquivos');
    // The confirmation states what is being confirmed.
    expect(html).toContain(
      'Confirmar a retirada dos 3 arquivos de 1 solicitação do lote LOT-0001?',
    );

    const unchecked = await browser.postForm(`/batches/${batch.id}/collected`, command(html));
    expect(unchecked.status).toBe(400);
    expect(await unchecked.text()).toContain('Marque “Conferi todos os arquivos”');
    expect((await h.api.getBatch(batch.id)).value.status).toBe('open');

    const unconfirmed = command(html, { checked: '1' });
    unconfirmed.delete('confirmed');
    expect((await browser.postForm(`/batches/${batch.id}/collected`, unconfirmed)).status).toBe(
      400,
    );

    const res = await browser.postForm(
      `/batches/${batch.id}/collected`,
      command(html, { checked: '1' }),
    );
    expect(res.status).toBe(303);
    expect(res.headers.get('location')).toBe('/?ok=collected');
    expect((await h.api.getBatch(batch.id)).value.status).toBe('files_collected');
    const after = await (await browser.get('/?ok=collected')).text();
    expect(after).toContain('Retirada confirmada.');
    expect(parseHtml(after).one('action').attrs['data-action']).toBe('upload-quote');
  });

  it('a stale ETag on collect → 412 shown, reload shows the change and requires reconfirmation', async () => {
    h.api.publishRequest({
      title: 'Primeira solicitação',
      jobs: [
        {
          title: 'Prova de Português',
          copies: 30,
          instructions: 'Frente e verso',
          file: { name: 'prova.pdf', mime: 'application/pdf', bytes: PDF_BYTES },
        },
      ],
    });
    await htmlLogin(browser);
    const { html } = await home(browser);
    const batchId = parseHtml(html).one('batch').attrs['data-batch-id'] as string;
    // A new request joins the open batch after the page was rendered.
    h.api.publishRequest({
      title: 'Solicitação nova',
      jobs: [
        {
          title: 'Lista extra',
          copies: 5,
          instructions: 'Uma face apenas',
          file: { name: 'extra.png', mime: 'image/png', bytes: PNG_BYTES },
        },
      ],
    });
    const stale = await browser.postForm(
      `/batches/${batchId}/collected`,
      command(html, { checked: '1' }),
    );
    expect(stale.status).toBe(412);
    const page = await stale.text();
    expect(page).toContain('O lote mudou desde que você o abriu');
    expect(page).toContain('Atualizar');
    // The re-rendered batch already shows the new member, with a fresh ETag
    // and key, and the checkbox must be ticked again.
    const doc = parseHtml(page);
    expect(doc.marked('item')).toHaveLength(2);
    expect(hidden(page, 'etag')).toBe(`"${batchId}:2"`);
    expect(hidden(page, 'idempotencyKey')).not.toBe(hidden(html, 'idempotencyKey'));
    expect(page).not.toMatch(/name="checked"[^>]*checked/);
    expect((await h.api.getBatch(batchId)).value.status).toBe('open');

    const reconfirmed = await browser.postForm(
      `/batches/${batchId}/collected`,
      command(page, { checked: '1' }),
    );
    expect(reconfirmed.status).toBe(303);
    const collected = (await h.api.getBatch(batchId)).value;
    expect(collected.status).toBe('files_collected');
    expect(collected.items).toHaveLength(2);
  });

  it('quote upload: disallowed type and oversized file get clear errors; valid → quote_pending', async () => {
    const batch = fixtureBatch('files_collected');
    h.api.seedBatch(batch, V2_ASSETS);
    await htmlLogin(browser);
    const { html } = await home(browser);

    const text = new File(['not a quote'], 'orcamento.txt', { type: 'text/plain' });
    const badType = await browser.postForm(`/batches/${batch.id}/quotes`, quoteForm(html, text));
    expect(badType.status).toBe(415);
    const badTypePage = await badType.text();
    expect(badTypePage).toContain('Formato de arquivo não aceito. Envie PDF, JPEG, PNG ou WebP.');
    expect(badTypePage).toContain('value="459,00"');

    const huge = new File([new Uint8Array(5 * 1024 * 1024 + 1)], 'grande.pdf', {
      type: 'application/pdf',
    });
    const tooBig = await browser.postForm(`/batches/${batch.id}/quotes`, quoteForm(html, huge));
    expect(tooBig.status).toBe(413);
    expect(await tooBig.text()).toContain('Arquivo acima de 5 MB.');

    const badAmount = await browser.postForm(
      `/batches/${batch.id}/quotes`,
      quoteForm(html, new File([PDF_BYTES], 'orcamento.pdf'), '12.34'),
    );
    expect(badAmount.status).toBe(400);
    expect(await badAmount.text()).toContain('Valor total do orçamento inválido');
    expect((await h.api.getBatch(batch.id)).value.status).toBe('files_collected');

    const ok = await browser.postForm(
      `/batches/${batch.id}/quotes`,
      quoteForm(html, new File([PDF_BYTES], 'orcamento.pdf'), 'R$ 1.234,56'),
    );
    expect(ok.status).toBe(303);
    expect(ok.headers.get('location')).toBe('/?ok=quote');
    const pending = (await h.api.getBatch(batch.id)).value;
    expect(pending.status).toBe('quote_pending');
    expect(pending.currentQuote?.amountCents).toBe(123456);
    const after = await (await browser.get('/?ok=quote')).text();
    expect(parseHtml(after).one('status-message').text()).toBe(
      'Aguardando aprovação do Financeiro',
    );
    expect(after).toContain('R$ 1.234,56');
  });

  /** A harness whose upstream answers the next submitQuote with a 503, before or after committing it. */
  function flakyQuotes() {
    const real = new PrintApiMemory({ clock: () => new Date('2026-10-08T12:00:00Z') });
    const fault = { next: null as 'before' | 'after' | null };
    const flaky = new Proxy(real, {
      get(target, prop, receiver) {
        const value = Reflect.get(target, prop, receiver);
        if (prop === 'submitQuote') {
          return async (...args: Parameters<PrintApiMemory['submitQuote']>) => {
            const when = fault.next;
            fault.next = null;
            if (when === 'before') throw new UpstreamUnavailableError('timeout');
            const result = await target.submitQuote(...args);
            if (when === 'after') throw new UpstreamUnavailableError('upstream status 503');
            return result;
          };
        }
        return typeof value === 'function' ? value.bind(target) : value;
      },
    });
    const batch = fixtureBatch('files_collected');
    real.seedBatch(batch, V2_ASSETS);
    return { real, fault, batch, hf: createHarness({ printApi: flaky }) };
  }

  it('a quote retried after a 503 reuses the Idempotency-Key: one quote, no duplicate', async () => {
    const { real, fault, batch, hf } = flakyQuotes();
    const b = hf.client();
    await htmlLogin(b);
    const html = await (await b.get('/')).text();
    const key = hidden(html, 'idempotencyKey');

    fault.next = 'before';
    const first = await b.postForm(
      `/batches/${batch.id}/quotes`,
      quoteForm(html, new File([PDF_BYTES], 'orcamento.pdf')),
    );
    expect(first.status).toBe(503);
    const retryPage = await first.text();
    expect(retryPage).toContain('Serviço indisponível');
    // Same intent → same key and ETag, amount kept; the file must be chosen again.
    expect(hidden(retryPage, 'idempotencyKey')).toBe(key);
    expect(hidden(retryPage, 'etag')).toBe(hidden(html, 'etag'));
    expect(retryPage).toContain('value="459,00"');

    const retry = await b.postForm(
      `/batches/${batch.id}/quotes`,
      quoteForm(retryPage, new File([PDF_BYTES], 'orcamento.pdf')),
    );
    expect(retry.status).toBe(303);
    const quoted = (await real.getBatch(batch.id)).value;
    expect(quoted.status).toBe('quote_pending');
    expect(quoted.currentQuote?.revision).toBe(1);
    expect(quoted.version).toBe(batch.version + 1);
  });

  it('a 503 after the upstream committed: the page shows the truth and resubmitting replays', async () => {
    const { real, fault, batch, hf } = flakyQuotes();
    const b = hf.client();
    await htmlLogin(b);
    const html = await (await b.get('/')).text();
    const form = () => quoteForm(html, new File([PDF_BYTES], 'orcamento.pdf'));

    fault.next = 'after';
    const first = await b.postForm(`/batches/${batch.id}/quotes`, form());
    expect(first.status).toBe(503);
    const page = parseHtml(await first.text());
    expect(page.one('batch').attrs['data-status']).toBe('quote_pending');
    expect(page.marked('action')).toEqual([]);

    // The browser re-sends the same form: same key + intent → replay, not a second quote.
    const resent = await b.postForm(`/batches/${batch.id}/quotes`, form());
    expect(resent.status).toBe(303);
    const quoted = (await real.getBatch(batch.id)).value;
    expect(quoted.currentQuote?.revision).toBe(1);
    expect(quoted.version).toBe(batch.version + 1);
  });

  it('quote_approved → "Marcar como impresso" (confirmed) → printed', async () => {
    const batch = fixtureBatch('quote_approved');
    h.api.seedBatch(batch, V2_ASSETS);
    await htmlLogin(browser);
    const { html } = await home(browser);
    expect(html).toContain('Confirmar que todo o lote LOT-0001 foi impresso?');
    expect(html).toContain('R$ 459,00');
    const quoteId = hidden(html, 'quoteId');
    expect(quoteId).toBe(batch.currentQuote?.id);

    const unconfirmed = command(html, { quoteId });
    unconfirmed.delete('confirmed');
    expect((await browser.postForm(`/batches/${batch.id}/printed`, unconfirmed)).status).toBe(400);
    expect((await h.api.getBatch(batch.id)).value.status).toBe('quote_approved');

    const res = await browser.postForm(`/batches/${batch.id}/printed`, command(html, { quoteId }));
    expect(res.status).toBe(303);
    expect(res.headers.get('location')).toBe('/?ok=printed');
    expect((await h.api.getBatch(batch.id)).value.status).toBe('printed');
    const after = parseHtml(await (await browser.get('/?ok=printed')).text());
    expect(after.marked('action')).toEqual([]);
    expect(after.one('status-message').text()).toBe('Aguardando recebimento');
  });

  it('a command for a state that no longer allows it is refused upstream, never faked', async () => {
    const batch = fixtureBatch('quote_pending');
    h.api.seedBatch(batch, V2_ASSETS);
    await htmlLogin(browser);
    const { html } = await home(browser);
    const res = await browser.postForm(
      `/batches/${batch.id}/collected`,
      new URLSearchParams({
        _csrf: hidden(html, '_csrf'),
        idempotencyKey: '7d3c0d9e-5b8e-4c1f-9a51-111111111111',
        etag: `"${batch.id}:${batch.version}"`,
        checked: '1',
        confirmed: '1',
      }),
    );
    expect(res.status).toBe(409);
    expect(await res.text()).toContain('Esta ação não é mais possível no estado atual.');
  });

  it('an unreachable upstream keeps the session and offers Atualizar', async () => {
    const down = new Proxy(h.api, {
      get(target, prop, receiver) {
        if (prop === 'getOpenBatch') {
          return async () => {
            throw new UpstreamUnavailableError('timeout');
          };
        }
        const value = Reflect.get(target, prop, receiver);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    });
    const hd = createHarness({ printApi: down });
    const b = hd.client();
    await htmlLogin(b);
    const res = await b.get('/');
    expect(res.status).toBe(503);
    const page = await res.text();
    expect(page).toContain('Serviço indisponível');
    expect(page).toContain('Atualizar');
    expect(page).toContain('Sair');
    expect(parseHtml(page).marked('empty')).toEqual([]);
  });
});

describe('portal HTML — Lotes anteriores', () => {
  it('lists every batch with status, dates and approved amount, and a read-only detail', async () => {
    const h = createHarness();
    const browser = h.client();
    const received = fixtureBatch('received');
    h.api.seedBatch(received, V2_ASSETS);
    h.api.seedBatch(structuredClone(V2_FIXTURE.nextBatch.batch), V2_ASSETS);
    await htmlLogin(browser);

    const res = await browser.get('/batches');
    expect(res.status).toBe(200);
    const list = await res.text();
    expect(list).toContain('Lotes anteriores');
    const rows = parseHtml(list).marked('history-batch');
    expect(rows.map((r) => r.attrs['data-batch-id'])).toEqual([
      received.id,
      V2_FIXTURE.nextBatch.batch.id,
    ]);
    const first = (rows[0] as HtmlNode).text();
    expect(first).toContain('LOT-0001');
    expect(first).toContain('Recebido');
    expect(first).toContain('R$ 459,00');
    expect(first).toContain('10/09/2026');

    const detail = await browser.get(`/batches/${received.id}`);
    expect(detail.status).toBe(200);
    const doc = parseHtml(await detail.text());
    expectBatchMarkers(doc, received);
    expect(doc.marked('action')).toEqual([]);
    expect(doc.one('batch').text()).toContain('Recebido em');

    expect((await browser.get('/batches/00000000-0000-4000-8000-0000000000ff')).status).toBe(404);
    expect((await browser.get('/batches/not-a-uuid')).status).toBe(404);
  });

  it('empty history renders its own empty state', async () => {
    const h = createHarness();
    const browser = h.client();
    await htmlLogin(browser);
    const list = await (await browser.get('/batches')).text();
    expect(list).toContain('Nenhum lote anterior.');
  });
});
