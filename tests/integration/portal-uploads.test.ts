/**
 * Quote and NF uploads end to end over a real HTTP boundary: HTML form →
 * portal → PrintApiHttp → fake upstream that, like the real one, refuses a
 * multipart part whose declared type differs from its sniffed content.
 */
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PrintApiHttp } from '../../src/adapters/print-api.http.js';
import { type FakeUpstream, startFakeUpstream } from '../helpers/fake-print-upstream.js';
import { createHarness, PASSWORD, type PortalClient } from '../helpers/portal-harness.js';
import { PDF_BYTES } from '../helpers/print-fixtures.js';
import { fixtureBatch, V2_ASSETS } from '../helpers/print-v2-fixture.js';

function hidden(page: string, name: string): string {
  const match = new RegExp(`name="${name}" value="([^"]*)"`).exec(page);
  if (!match?.[1]) throw new Error(`hidden field ${name} not found`);
  return match[1].replaceAll('&quot;', '"');
}

async function htmlLogin(browser: PortalClient): Promise<void> {
  const page = await (await browser.get('/login')).text();
  await browser.postForm(
    '/login',
    new URLSearchParams({ _csrf: hidden(page, '_csrf'), password: PASSWORD }),
  );
}

/** Upload form as a browser that sends no (or a wrong) file type would. */
function uploadForm(page: string, amount: string, type: string): FormData {
  const form = new FormData();
  for (const name of ['_csrf', 'idempotencyKey', 'etag']) form.set(name, hidden(page, name));
  form.set('confirmed', '1');
  form.set('amount', amount);
  form.set('file', new File([PDF_BYTES], 'documento.pdf', { type }));
  return form;
}

describe('uploads through the HTTP adapter', () => {
  let upstream: FakeUpstream;
  beforeAll(async () => {
    upstream = await startFakeUpstream();
  });
  afterAll(() => upstream.close());

  it('a valid PDF quote reaches quote_pending even when the browser sends no type', async () => {
    const batch = fixtureBatch('files_collected');
    upstream.api.seedBatch(batch, V2_ASSETS);
    const h = createHarness({
      printApi: new PrintApiHttp({ origin: upstream.origin, token: upstream.token }),
    });
    const browser = h.client();
    await htmlLogin(browser);
    const page = await (await browser.get('/')).text();
    const res = await browser.postForm(
      `/batches/${batch.id}/quotes`,
      uploadForm(page, '459,00', ''),
    );
    expect(res.status).toBe(303);
    const quoted = (await upstream.api.getBatch(batch.id)).value;
    expect(quoted.status).toBe('quote_pending');
    expect(quoted.currentQuote?.document.mime).toBe('application/pdf');
  });

  it('a valid PDF NF is accepted for a closed competence', async () => {
    upstream.api.seedLegacyCharge({
      reference: 'IMP-0301',
      amountCents: 1_000,
      printedAt: '2026-09-10T12:00:00.000Z',
    });
    const h = createHarness({
      printApi: new PrintApiHttp({ origin: upstream.origin, token: upstream.token }),
    });
    const browser = h.client();
    await htmlLogin(browser);
    const page = await (await browser.get('/invoices?competence=2026-09')).text();
    const res = await browser.postForm(
      '/invoices/2026-09',
      uploadForm(page, '10,00', 'application/octet-stream'),
    );
    expect(res.status).toBe(303);
    const close = (await upstream.api.getMonthlyClose('2026-09')).value;
    expect(close.state).toBe('submitted');
    expect(close.document?.mime).toBe('application/pdf');
  });
});
