/**
 * Shared conformance suite for PrintApi implementations.
 *
 * Runs the same behavioural + span assertions against PrintApiMemory
 * directly and against PrintApiHttp talking to a real HTTP server
 * (tests/helpers/fake-print-upstream.ts). The memory fake is the "staff
 * side" in both cases: it seeds orders and decides quotes.
 *
 * Every response is also validated against the Zod mirror of the frozen
 * contract, so neither adapter can drift from print-portal-v1.schema.json.
 */
import { randomUUID } from 'node:crypto';
import type { ReadableSpan } from '@opentelemetry/sdk-trace-base';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  CloseResponseSchema,
  OrderListResponseSchema,
  OrderResponseSchema,
} from '../../src/adapters/print-api.contract.js';
import type { PrintApi } from '../../src/adapters/print-api.js';
import type { PrintApiMemory } from '../../src/adapters/print-api.memory.js';
import { competenceOf } from '../../src/domain/monthly-close.js';
import { UpstreamRejectedError } from '../../src/errors/upstream-rejected.error.js';
import { PDF_BYTES, PNG_BYTES, seedTwoFileOrder } from './print-fixtures.js';

export interface PrintApiConformanceOptions {
  /** Fresh adapter + the memory fake that backs it (staff/seed side). */
  factory: () => Promise<{ api: PrintApi; staff: PrintApiMemory }>;
  getSpans: () => ReadableSpan[];
  resetSpans: () => void;
  expectedServerAddress: (staff: PrintApiMemory) => string | RegExp;
}

async function rejection(promise: Promise<unknown>): Promise<UpstreamRejectedError> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(UpstreamRejectedError);
    return error as UpstreamRejectedError;
  }
  throw new Error('expected an upstream rejection');
}

async function readAll(stream: ReadableStream<Uint8Array>): Promise<Uint8Array> {
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

export function describePrintApiConformance(name: string, options: PrintApiConformanceOptions) {
  describe(`PrintApi conformance — ${name}`, () => {
    let api: PrintApi;
    let staff: PrintApiMemory;

    beforeEach(async () => {
      ({ api, staff } = await options.factory());
      options.resetSpans();
    });

    it('lists only this supplier’s orders, createdAt ASC, with keyset pagination', async () => {
      const a = seedTwoFileOrder(staff);
      staff.seedOrder({ supplierId: 'supplier-b', jobs: [] as never });
      const b = seedTwoFileOrder(staff);
      const c = seedTwoFileOrder(staff);

      const first = await api.listOrders({ limit: 2 });
      expect(OrderListResponseSchema.safeParse(first).success).toBe(true);
      expect(first.items.map((o) => o.id)).toEqual([a.id, b.id]);
      expect(first.nextCursor).not.toBeNull();

      const second = await api.listOrders({ limit: 2, cursor: first.nextCursor ?? '' });
      expect(second.items.map((o) => o.id)).toEqual([c.id]);
      expect(second.nextCursor).toBeNull();
    });

    it('filters by status and rejects a cursor minted for another filter', async () => {
      const a = seedTwoFileOrder(staff);
      seedTwoFileOrder(staff);
      const order = await api.getOrder(a.id);
      await api.markCollected(
        a.id,
        { revision: 1 },
        { ifMatch: order.etag, idempotencyKey: randomUUID() },
      );

      const collected = await api.listOrders({ limit: 20, status: 'files_collected' });
      expect(collected.items.map((o) => o.id)).toEqual([a.id]);

      const page = await api.listOrders({ limit: 1 });
      const err = await rejection(
        api.listOrders({ limit: 1, status: 'ready', cursor: page.nextCursor ?? '' }),
      );
      expect([err.status, err.code]).toEqual([400, 'INVALID_CURSOR']);
    });

    it('gets an order with its ETag; foreign and unknown ids are 404', async () => {
      const a = seedTwoFileOrder(staff);
      const foreign = staff.seedOrder({
        supplierId: 'supplier-b',
        jobs: [
          {
            title: 'Outro',
            copies: 1,
            instructions: 'Nada demais',
            file: { name: 'x.pdf', mime: 'application/pdf', bytes: PDF_BYTES },
          },
        ],
      });

      const got = await api.getOrder(a.id);
      expect(OrderResponseSchema.safeParse({ order: got.value }).success).toBe(true);
      expect(got.etag).toBe(`"${a.id}:1"`);
      expect(got.value.jobs.map((j) => j.copies)).toEqual([2, 7]);

      for (const id of [foreign.id, randomUUID(), 'not-a-uuid']) {
        const err = await rejection(api.getOrder(id));
        expect([err.status, err.code]).toEqual([404, 'NOT_FOUND']);
      }
    });

    it('streams the exact bytes of each job file; foreign file ids are 404', async () => {
      const a = seedTwoFileOrder(staff);
      const [math, physics] = a.jobs;
      if (!math || !physics) throw new Error('fixture');

      const d1 = await api.downloadOrderFile(a.id, math.file.id);
      expect(d1.mime).toBe('application/pdf');
      expect(d1.size).toBe(math.file.bytes);
      expect(d1.filename).toBe(math.file.name);
      expect(Buffer.from(await readAll(d1.body)).equals(Buffer.from(PDF_BYTES))).toBe(true);

      const d2 = await api.downloadOrderFile(a.id, physics.file.id);
      expect(Buffer.from(await readAll(d2.body)).equals(Buffer.from(PNG_BYTES))).toBe(true);

      const other = seedTwoFileOrder(staff);
      const err = await rejection(api.downloadOrderFile(other.id, math.file.id));
      expect(err.status).toBe(404);
      // GET of a file never changes the order.
      expect((await api.getOrder(a.id)).value.status).toBe('ready');
    });

    it('collect: 428 without preconditions, 412 on stale ETag, 200 + new ETag, replay on same key', async () => {
      const a = seedTwoFileOrder(staff);
      const { etag } = await api.getOrder(a.id);

      const missing = await rejection(api.markCollected(a.id, { revision: 1 }, {}));
      expect([missing.status, missing.code]).toEqual([428, 'PRECONDITION_REQUIRED']);

      const stale = await rejection(
        api.markCollected(
          a.id,
          { revision: 1 },
          { ifMatch: `"${a.id}:99"`, idempotencyKey: randomUUID() },
        ),
      );
      expect([stale.status, stale.code]).toEqual([412, 'VERSION_MISMATCH']);

      const key = randomUUID();
      const done = await api.markCollected(
        a.id,
        { revision: 1 },
        { ifMatch: etag, idempotencyKey: key },
      );
      expect(done.status).toBe(200);
      expect(done.replayed).toBe(false);
      expect(done.value.status).toBe('files_collected');
      expect(done.value.collectedAt).not.toBeNull();
      expect(done.etag).toBe(`"${a.id}:2"`);

      const replay = await api.markCollected(
        a.id,
        { revision: 1 },
        { ifMatch: etag, idempotencyKey: key },
      );
      expect(replay.replayed).toBe(true);
      expect(replay.etag).toBe(done.etag);
      expect(replay.value).toEqual(done.value);

      const conflict = await rejection(
        api.markCollected(a.id, { revision: 2 }, { ifMatch: etag, idempotencyKey: key }),
      );
      expect([conflict.status, conflict.code]).toEqual([409, 'IDEMPOTENCY_CONFLICT']);

      const again = await rejection(
        api.markCollected(
          a.id,
          { revision: 1 },
          { ifMatch: done.etag, idempotencyKey: randomUUID() },
        ),
      );
      expect([again.status, again.code]).toEqual([409, 'INVALID_STATE']);
    });

    it('full journey: collect → quote → approve → printed; early print is refused', async () => {
      const a = seedTwoFileOrder(staff);
      let { etag } = await api.getOrder(a.id);
      ({ etag } = await api.markCollected(
        a.id,
        { revision: 1 },
        { ifMatch: etag, idempotencyKey: randomUUID() },
      ));

      const quoted = await api.submitQuote(
        a.id,
        {
          amountCents: 45_900,
          orderRevision: 1,
          file: { filename: 'orçamento.pdf', bytes: PDF_BYTES },
        },
        { ifMatch: etag, idempotencyKey: randomUUID() },
      );
      expect(quoted.status).toBe(201);
      expect(quoted.value.status).toBe('quote_pending');
      const quote = quoted.value.currentQuote;
      expect(quote?.amountCents).toBe(45_900);
      expect(quote?.decision).toBe('pending');
      if (!quote) throw new Error('quote');

      const early = await rejection(
        api.markPrinted(
          a.id,
          { revision: 1, quoteId: quote.id },
          { ifMatch: quoted.etag, idempotencyKey: randomUUID() },
        ),
      );
      expect([early.status, early.code]).toEqual([409, 'INVALID_STATE']);

      const doc = await api.downloadQuoteFile(a.id, quote.id);
      expect(Buffer.from(await readAll(doc.body)).equals(Buffer.from(PDF_BYTES))).toBe(true);

      staff.approveQuote(a.id);
      const approved = await api.getOrder(a.id);
      expect(approved.value.status).toBe('quote_approved');
      expect(approved.value.approvedAmountCents).toBe(45_900);

      const printed = await api.markPrinted(
        a.id,
        { revision: 1, quoteId: quote.id },
        { ifMatch: approved.etag, idempotencyKey: randomUUID() },
      );
      expect(printed.value.status).toBe('printed');
      expect(printed.value.printedAt).not.toBeNull();
    });

    it('quote upload: unsupported type 415, rejected quote allows a new revision', async () => {
      const a = seedTwoFileOrder(staff);
      let { etag } = await api.getOrder(a.id);
      ({ etag } = await api.markCollected(
        a.id,
        { revision: 1 },
        { ifMatch: etag, idempotencyKey: randomUUID() },
      ));

      const html = await rejection(
        api.submitQuote(
          a.id,
          {
            amountCents: 100,
            orderRevision: 1,
            file: { filename: 'x.html', bytes: new TextEncoder().encode('<html>') },
          },
          { ifMatch: etag, idempotencyKey: randomUUID() },
        ),
      );
      expect([html.status, html.code]).toEqual([415, 'UNSUPPORTED_MEDIA_TYPE']);

      const first = await api.submitQuote(
        a.id,
        { amountCents: 100, orderRevision: 1, file: { filename: 'q1.png', bytes: PNG_BYTES } },
        { ifMatch: etag, idempotencyKey: randomUUID() },
      );
      staff.rejectQuote(a.id, 'Valor acima do combinado');
      const rejected = await api.getOrder(a.id);
      expect(rejected.value.status).toBe('quote_rejected');
      expect(rejected.value.currentQuote?.rejectionReason).toBe('Valor acima do combinado');

      const second = await api.submitQuote(
        a.id,
        { amountCents: 90, orderRevision: 1, file: { filename: 'q2.pdf', bytes: PDF_BYTES } },
        { ifMatch: rejected.etag, idempotencyKey: randomUUID() },
      );
      expect(second.value.currentQuote?.revision).toBe(
        (first.value.currentQuote?.revision ?? 0) + 1,
      );
    });

    it('monthly close: virtual empty close, PERIOD_OPEN for the current month', async () => {
      const current = competenceOf(new Date());
      const empty = await api.getMonthlyClose('2001-01');
      expect(CloseResponseSchema.safeParse({ close: empty.value }).success).toBe(true);
      expect(empty.value).toMatchObject({
        id: null,
        version: 0,
        state: 'open',
        items: [],
        expectedTotalCents: 0,
      });
      expect(empty.etag).toBe('"month:2001-01:0"');

      const emptySubmit = await rejection(
        api.submitInvoice(
          '2001-01',
          { declaredTotalCents: 100, file: { filename: 'nf.pdf', bytes: PDF_BYTES } },
          { ifMatch: empty.etag, idempotencyKey: randomUUID() },
        ),
      );
      expect([emptySubmit.status, emptySubmit.code]).toEqual([409, 'EMPTY_CLOSE']);

      const now = await api.getMonthlyClose(current);
      expect(now.value.periodClosed).toBe(false);
      const open = await rejection(
        api.submitInvoice(
          current,
          { declaredTotalCents: 100, file: { filename: 'nf.pdf', bytes: PDF_BYTES } },
          { ifMatch: now.etag, idempotencyKey: randomUUID() },
        ),
      );
      expect([open.status, open.code]).toEqual([409, 'PERIOD_OPEN']);

      const invalid = await rejection(api.getMonthlyClose('2026-13'));
      expect([invalid.status, invalid.code]).toEqual([400, 'INVALID_COMPETENCE']);

      const none = await rejection(api.downloadInvoice('2001-01'));
      expect(none.status).toBe(404);
    });

    it('emits one print_api.<operation> span per call with HTTP-shaped attributes', async () => {
      const a = seedTwoFileOrder(staff);
      options.resetSpans();
      await api.getOrder(a.id);
      await rejection(api.getOrder(randomUUID()));

      // Only this adapter's spans (the HTTP fake's own memory adapter also traces).
      const address = options.expectedServerAddress(staff);
      const mine = (value: unknown) =>
        typeof address === 'string' ? value === address : address.test(String(value));
      const spans = options
        .getSpans()
        .filter((s) => s.name.startsWith('print_api.') && mine(s.attributes['server.address']));
      expect(spans.map((s) => s.name)).toEqual(['print_api.getOrder', 'print_api.getOrder']);
      const [ok, failed] = spans;
      expect(ok?.attributes['http.request.method']).toBe('GET');
      expect(ok?.attributes['url.template']).toBe('/api/print-portal/v1/orders/:id');
      expect(ok?.attributes['print_api.operation']).toBe('getOrder');
      expect(ok?.status.code).toBe(1);
      expect(failed?.status.code).toBe(2);
      expect(failed?.attributes['print_api.error.code']).toBe('NOT_FOUND');
      expect(failed?.events.some((e) => e.name === 'exception')).toBe(true);
    });
  });
}
