/**
 * Spec §8 case 13 (portal side): with a real OTel SDK exporter, a capturing
 * logger and the real HTTP adapter against the fake upstream, run the
 * journey plus malformed/unauthorised requests, then assert that no marker
 * (password, service token, CSRF token, session id, instructions, file
 * names, document bytes) appears in any span attribute/event or log line,
 * and that error responses never echo input.
 */
import { randomUUID } from 'node:crypto';
import type { ReadableSpan } from '@opentelemetry/sdk-trace-base';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PrintApiHttp } from '../../src/adapters/print-api.http.js';
import { type FakeUpstream, startFakeUpstream } from '../helpers/fake-print-upstream.js';
import { createTestObservability } from '../helpers/observability.js';
import { createHarness, PASSWORD } from '../helpers/portal-harness.js';
import { PDF_BYTES } from '../helpers/print-fixtures.js';

const INSTRUCTIONS = 'MARKER-INSTRUCTIONS frente e verso';
const FILENAME = 'MARKER-FILENAME.pdf';
const QUOTE_NAME = 'MARKER-QUOTE.pdf';

const obs = createTestObservability();
let upstream: FakeUpstream;

beforeAll(async () => {
  upstream = await startFakeUpstream();
});
afterAll(async () => {
  await upstream.close();
  await obs.shutdown();
});

function spanText(spans: ReadableSpan[]): string {
  return JSON.stringify(
    spans.map((s) => ({
      name: s.name,
      attributes: s.attributes,
      status: s.status,
      events: s.events.map((e) => ({ name: e.name, attributes: e.attributes })),
    })),
  );
}

describe('confidentiality of telemetry and errors', () => {
  it('no secret or document content reaches spans, logs or error bodies', async () => {
    const h = createHarness({
      printApi: new PrintApiHttp({ origin: upstream.origin, token: upstream.token }),
      observability: obs.observability,
    });
    const order = upstream.api.seedOrder({
      jobs: [
        {
          title: 'Apostila',
          copies: 3,
          instructions: INSTRUCTIONS,
          file: { name: FILENAME, mime: 'application/pdf', bytes: PDF_BYTES },
        },
      ],
    });
    const browser = h.client({ ip: '203.0.113.50' });
    const errorBodies: string[] = [];
    const keep = async (res: Response) => {
      if (res.status >= 400) errorBodies.push(await res.clone().text());
      return res;
    };

    // Login: wrong, malformed, scalar, truncated, then right.
    await keep(await browser.login('MARKER-WRONG-PASSWORD-123'));
    await keep(await browser.post('/api/session', 'MARKER-SCALAR'));
    await keep(
      await browser.request('POST', '/api/session', {
        body: '{"password":"MARKER-TRUNC',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': browser.csrf ?? '' },
      }),
    );
    expect((await browser.login()).status).toBe(200);
    const csrf = browser.csrf ?? '';
    const sessionId = browser.cookies.get('__Host-print_session') ?? '';

    // Journey with downloads and an upload.
    const detail = await browser.get(`/api/print/v1/orders/${order.id}`);
    const fileId = order.jobs[0]?.file.id ?? '';
    await (await browser.get(`/api/print/v1/orders/${order.id}/files/${fileId}`)).arrayBuffer();
    const collected = await browser.post(
      `/api/print/v1/orders/${order.id}/collected`,
      { revision: 1 },
      { 'If-Match': detail.headers.get('etag') ?? '', 'Idempotency-Key': randomUUID() },
    );
    const form = new FormData();
    form.append('file', new File([PDF_BYTES], QUOTE_NAME));
    form.append('amountCents', '45900');
    form.append('orderRevision', '1');
    await browser.request('POST', `/api/print/v1/orders/${order.id}/quotes`, {
      body: form,
      headers: {
        'X-CSRF-Token': csrf,
        'If-Match': collected.headers.get('etag') ?? '',
        'Idempotency-Key': randomUUID(),
      },
    });

    // Failures: 400/401/403/404/405/412/428/503.
    await keep(
      await browser.post(`/api/print/v1/orders/${order.id}/collected`, { revision: 'MARKER-BAD' }),
    );
    await keep(await h.client().get('/api/print/v1/orders'));
    await keep(
      await browser.request('POST', `/api/print/v1/orders/${order.id}/printed`, {
        json: {},
        headers: { 'X-CSRF-Token': 'MARKER-CSRF-BAD' },
      }),
    );
    await keep(await browser.get(`/api/print/v1/orders/${randomUUID()}`));
    await keep(await browser.request('PUT', `/api/print/v1/orders/${order.id}`));
    await keep(
      await browser.post(
        `/api/print/v1/orders/${order.id}/collected`,
        { revision: 1 },
        { 'If-Match': '"stale:0"', 'Idempotency-Key': randomUUID() },
      ),
    );
    await keep(await browser.post(`/api/print/v1/orders/${order.id}/collected`, { revision: 1 }));
    upstream.behaviour.failWith = 503;
    await keep(await browser.get('/api/print/v1/orders'));
    upstream.behaviour.failWith = 0;

    const spans = obs.getSpans();
    expect(spans.length).toBeGreaterThan(10);
    const telemetry = `${spanText(spans)}\n${JSON.stringify(h.logger.lines)}`;
    const errors = errorBodies.join('\n');
    const markers = [
      PASSWORD,
      upstream.token,
      csrf,
      sessionId,
      INSTRUCTIONS,
      'MARKER',
      FILENAME,
      QUOTE_NAME,
      '%PDF',
    ];
    for (const marker of markers) {
      expect(telemetry, `telemetry leaks ${marker.slice(0, 12)}…`).not.toContain(marker);
      expect(errors, `error body leaks ${marker.slice(0, 12)}…`).not.toContain(marker);
    }

    // Use cases are traced by name, adapter calls nest under them.
    const names = new Set(spans.map((s) => s.name));
    for (const name of [
      'logIn',
      'authenticateSession',
      'getOrder',
      'downloadOrderFile',
      'collectOrderFiles',
      'submitQuote',
      'print_api.submitQuote',
    ]) {
      expect(names.has(name), name).toBe(true);
    }
    const useCase = spans.find((s) => s.name === 'collectOrderFiles');
    const adapter = spans.find(
      (s) => s.name === 'print_api.markCollected' && s.attributes['server.address'] !== 'memory',
    );
    expect(adapter?.parentSpanContext?.spanId).toBe(useCase?.spanContext().spanId);
  });
});
