/**
 * Shared conformance suite for PrintApi implementations.
 *
 * Runs the same behavioural + span assertions against PrintApiMemory
 * directly and against PrintApiHttp talking to a real HTTP server
 * (tests/helpers/fake-print-upstream.ts). The memory fake is the "staff
 * side" in both cases: it publishes requests, decides quotes, receives
 * and cancels batches.
 *
 * Every response is also validated against the Zod mirror of the frozen
 * contract, so neither adapter can drift from print-portal-v2.schema.json.
 */
import { randomUUID } from 'node:crypto';
import type { ReadableSpan } from '@opentelemetry/sdk-trace-base';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  BatchListResponseSchema,
  BatchResponseSchema,
  CloseResponseSchema,
  OpenBatchResponseSchema,
} from '../../src/adapters/print-api.contract.js';
import type { PrintApi } from '../../src/adapters/print-api.js';
import type { PrintApiMemory } from '../../src/adapters/print-api.memory.js';
import { competenceOf } from '../../src/domain/monthly-close.js';
import { UpstreamRejectedError } from '../../src/errors/upstream-rejected.error.js';
import { PDF_BYTES, PNG_BYTES, seedTwoFileRequest } from './print-fixtures.js';

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

    /** Publish a request and return the open batch it joined, with its ETag. */
    async function openWith(title?: string) {
      const item = seedTwoFileRequest(staff, title);
      const open = await api.getOpenBatch();
      if (!open) throw new Error('expected an open batch');
      return { item, batch: open.value, etag: open.etag };
    }

    const key = () => ({ idempotencyKey: randomUUID() });

    it('one open batch per supplier; foreign/unknown ids are 404; history lists createdAt ASC', async () => {
      expect(await api.getOpenBatch()).toBeNull();
      const { item, batch, etag } = await openWith('Primeira');
      staff.publishRequest({ supplierId: 'supplier-b', jobs: [] });
      const second = seedTwoFileRequest(staff, 'Segunda');
      const open = await api.getOpenBatch();
      expect(OpenBatchResponseSchema.safeParse({ batch: open?.value }).success).toBe(true);
      expect(open?.value.id).toBe(batch.id);
      expect(open?.value.items.map((i) => i.orderId)).toEqual([item.orderId, second.orderId]);
      expect(open?.value.itemCount).toBe(2);
      expect(open?.etag).toBe(`"${batch.id}:2"`);
      expect(etag).toBe(`"${batch.id}:1"`);

      const got = await api.getBatch(batch.id);
      expect(BatchResponseSchema.safeParse({ batch: got.value }).success).toBe(true);
      expect(got.etag).toBe(open?.etag);
      expect((await rejection(api.getBatch(randomUUID()))).status).toBe(404);
      expect((await rejection(api.getBatch('not-a-uuid'))).status).toBe(404);

      const page = await api.listBatches({ limit: 20 });
      expect(BatchListResponseSchema.safeParse(page).success).toBe(true);
      expect(page.items.map((b) => b.id)).toEqual([batch.id]);
      expect((await api.listBatches({ limit: 20, status: 'printed' })).items).toEqual([]);
    });

    it('lists with keyset pagination; a cursor minted for another filter is refused', async () => {
      const { batch } = await openWith();
      await api.markCollected(batch.id, { ifMatch: `"${batch.id}:1"`, ...key() });
      staff.cancelBatch(batch.id, 'Cancelamento de teste');
      const next = await api.getOpenBatch();
      const first = await api.listBatches({ limit: 1 });
      expect(first.items.map((b) => b.id)).toEqual([batch.id]);
      expect(first.nextCursor).not.toBeNull();
      const second = await api.listBatches({ limit: 1, cursor: first.nextCursor ?? '' });
      expect(second.items.map((b) => b.id)).toEqual([next?.value.id]);
      expect(second.nextCursor).toBeNull();
      const bad = await rejection(
        api.listBatches({ limit: 1, status: 'open', cursor: first.nextCursor ?? '' }),
      );
      expect([bad.status, bad.code]).toEqual([400, 'INVALID_CURSOR']);
    });

    it('streams the exact bytes of each member file; other ids are 404', async () => {
      const { item, batch } = await openWith();
      for (const [job, bytes] of [
        [item.jobs[0], PDF_BYTES],
        [item.jobs[1], PNG_BYTES],
      ] as const) {
        const download = await api.downloadBatchFile(batch.id, item.orderId, job?.file.id ?? '');
        expect(download.mime).toBe(job?.file.mime);
        expect(download.filename).toBe(job?.file.name);
        expect(download.size).toBe(bytes.byteLength);
        expect(await readAll(download.body)).toEqual(bytes);
      }
      const file = item.jobs[0]?.file.id ?? '';
      expect((await rejection(api.downloadBatchFile(batch.id, randomUUID(), file))).status).toBe(
        404,
      );
      expect(
        (await rejection(api.downloadBatchFile(batch.id, item.orderId, randomUUID()))).status,
      ).toBe(404);
      expect(
        (await rejection(api.downloadBatchFile(randomUUID(), item.orderId, file))).status,
      ).toBe(404);
    });

    it('collect: 428 without preconditions, 412 on a stale ETag, 200 + new ETag, replay on same key', async () => {
      const { batch, etag } = await openWith();
      const missing = await rejection(api.markCollected(batch.id, {}));
      expect([missing.status, missing.code]).toEqual([428, 'PRECONDITION_REQUIRED']);

      // Membership changed after the page was seen: the stale collection is refused.
      seedTwoFileRequest(staff, 'Chegou depois');
      const stale = await rejection(api.markCollected(batch.id, { ifMatch: etag, ...key() }));
      expect([stale.status, stale.code]).toEqual([412, 'VERSION_MISMATCH']);

      const fresh = await api.getBatch(batch.id);
      const intent = { ifMatch: fresh.etag, ...key() };
      const done = await api.markCollected(batch.id, intent);
      expect(done.status).toBe(200);
      expect(done.replayed).toBe(false);
      expect(done.value.status).toBe('files_collected');
      expect(done.value.items).toHaveLength(2);
      expect(done.etag).toBe(`"${batch.id}:3"`);
      expect(BatchResponseSchema.safeParse({ batch: done.value }).success).toBe(true);

      const replay = await api.markCollected(batch.id, intent);
      expect(replay.replayed).toBe(true);
      expect(replay.etag).toBe(done.etag);
      const conflict = await rejection(
        api.markCollected(batch.id, { ifMatch: done.etag, idempotencyKey: intent.idempotencyKey }),
      );
      expect([conflict.status, conflict.code]).toEqual([409, 'IDEMPOTENCY_CONFLICT']);
      const again = await rejection(api.markCollected(batch.id, { ifMatch: done.etag, ...key() }));
      expect([again.status, again.code]).toEqual([409, 'INVALID_STATE']);
      // While a batch is active there is no open batch; new requests wait.
      seedTwoFileRequest(staff, 'Na fila');
      expect(await api.getOpenBatch()).toBeNull();
      expect((await api.getBatch(batch.id)).value.items).toHaveLength(2);
    });

    it('full journey: collect → quote → approve → printed → received; early print refused', async () => {
      const { batch, etag } = await openWith();
      const collected = await api.markCollected(batch.id, { ifMatch: etag, ...key() });
      const early = await rejection(
        api.markPrinted(batch.id, { quoteId: randomUUID() }, { ifMatch: collected.etag, ...key() }),
      );
      expect([early.status, early.code]).toEqual([409, 'INVALID_STATE']);

      const quoted = await api.submitQuote(
        batch.id,
        { amountCents: 45_900, file: { filename: 'orçamento.pdf', bytes: PDF_BYTES } },
        { ifMatch: collected.etag, ...key() },
      );
      expect(quoted.status).toBe(201);
      expect(quoted.value.status).toBe('quote_pending');
      const quote = quoted.value.currentQuote;
      expect(quote).toMatchObject({ revision: 1, amountCents: 45_900, decision: 'pending' });
      const doc = await api.downloadQuoteFile(batch.id, quote?.id ?? '');
      expect(await readAll(doc.body)).toEqual(PDF_BYTES);

      staff.approveQuote(batch.id);
      const approved = await api.getBatch(batch.id);
      expect(approved.value.approvedAmountCents).toBe(45_900);
      const printed = await api.markPrinted(
        batch.id,
        { quoteId: quote?.id ?? '' },
        { ifMatch: approved.etag, ...key() },
      );
      expect(printed.value.status).toBe('printed');
      expect(printed.value.printedAt).not.toBeNull();

      seedTwoFileRequest(staff, 'Próximo lote');
      staff.receiveBatch(batch.id);
      expect((await api.getBatch(batch.id)).value.status).toBe('received');
      const next = await api.getOpenBatch();
      expect(next?.value.reference).toBe('LOT-0002');
      expect(next?.value.items.map((i) => i.title)).toEqual(['Próximo lote']);
    });

    it('quote upload: unsupported type 415; a rejected quote allows a new revision', async () => {
      const { batch, etag } = await openWith();
      const collected = await api.markCollected(batch.id, { ifMatch: etag, ...key() });
      const text = new TextEncoder().encode('not a document');
      const bad = await rejection(
        api.submitQuote(
          batch.id,
          { amountCents: 100, file: { filename: 'q.txt', bytes: text } },
          { ifMatch: collected.etag, ...key() },
        ),
      );
      expect([bad.status, bad.code]).toEqual([415, 'UNSUPPORTED_MEDIA_TYPE']);
      const first = await api.submitQuote(
        batch.id,
        { amountCents: 100, file: { filename: 'q.png', bytes: PNG_BYTES } },
        { ifMatch: collected.etag, ...key() },
      );
      expect(first.value.currentQuote?.document.mime).toBe('image/png');
      staff.rejectQuote(batch.id, 'Valor alto');
      const rejected = await api.getBatch(batch.id);
      expect(rejected.value.status).toBe('quote_rejected');
      expect(rejected.value.currentQuote?.rejectionReason).toBe('Valor alto');
      const second = await api.submitQuote(
        batch.id,
        { amountCents: 90, file: { filename: 'q.pdf', bytes: PDF_BYTES } },
        { ifMatch: rejected.etag, ...key() },
      );
      expect(second.value.currentQuote?.revision).toBe(2);
    });

    it('cancellation returns every member to the next open batch, flagged by the backend', async () => {
      const { item, batch, etag } = await openWith();
      await api.markCollected(batch.id, { ifMatch: etag, ...key() });
      const queued = seedTwoFileRequest(staff, 'Na fila');
      staff.cancelBatch(batch.id, 'Cancelamento integral');
      const cancelled = (await api.getBatch(batch.id)).value;
      expect(cancelled.status).toBe('cancelled');
      expect(cancelled.cancellationReason).toBe('Cancelamento integral');
      const next = await api.getOpenBatch();
      expect(next?.value.currentQuote).toBeNull();
      expect(next?.value.items.map((i) => [i.orderId, i.previouslyCancelledIn ?? null])).toEqual([
        [item.orderId, batch.reference],
        [queued.orderId, null],
      ]);
      expect(BatchResponseSchema.safeParse({ batch: next?.value }).success).toBe(true);
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
      const { batch } = await openWith();
      options.resetSpans();
      await api.getBatch(batch.id);
      await rejection(api.getBatch(randomUUID()));

      // Only this adapter's spans (the HTTP fake's own memory adapter also traces).
      const address = options.expectedServerAddress(staff);
      const mine = (value: unknown) =>
        typeof address === 'string' ? value === address : address.test(String(value));
      const spans = options
        .getSpans()
        .filter((s) => s.name.startsWith('print_api.') && mine(s.attributes['server.address']));
      expect(spans.map((s) => s.name)).toEqual(['print_api.getBatch', 'print_api.getBatch']);
      const [ok, failed] = spans;
      expect(ok?.attributes['http.request.method']).toBe('GET');
      expect(ok?.attributes['url.template']).toBe('/api/print-portal/v2/batches/:id');
      expect(ok?.attributes['print_api.operation']).toBe('getBatch');
      expect(ok?.status.code).toBe(1);
      expect(failed?.status.code).toBe(2);
      expect(failed?.attributes['print_api.error.code']).toBe('NOT_FOUND');
      // Type only: no exception event (message/stack never exported).
      expect(failed?.attributes['error.type']).toBe('NOT_FOUND');
      expect(failed?.status.message).toBe('NOT_FOUND');
      expect(failed?.events.some((e) => e.name === 'exception')).toBe(false);
    });
  });
}
