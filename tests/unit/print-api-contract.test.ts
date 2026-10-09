/**
 * The Zod mirror in src/adapters/print-api.contract.ts against the FROZEN
 * v2 batch contract copied verbatim from monorepo-incluir (#1053 @ 27022467):
 * every fixture body must parse, every $def must have a mirror, and the
 * mirror must refuse what the schema (and its semantic invariants) refuses.
 */
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  BatchListResponseSchema,
  BatchResponseSchema,
  BatchSummarySchema,
  CloseResponseSchema,
  ErrorSchema,
  OpenBatchResponseSchema,
} from '../../src/adapters/print-api.contract.js';
import { V2_FIXTURE } from '../helpers/print-v2-fixture.js';

const schema = JSON.parse(
  readFileSync(new URL('../helpers/print-portal-v2.schema.json', import.meta.url), 'utf8'),
) as { $defs: Record<string, unknown> };

const summaryOf = (batch: Record<string, unknown>) => {
  const { items: _items, currentQuote: _quote, cancellationReason: _reason, ...summary } = batch;
  return summary;
};

describe('frozen print-portal v2 contract', () => {
  it('mirrors every $def of the JSON Schema', () => {
    expect(Object.keys(schema.$defs).sort()).toEqual(
      [
        'Batch',
        'BatchClose',
        'BatchCloseItem',
        'BatchCloseResponse',
        'BatchError',
        'BatchItem',
        'BatchListResponse',
        'BatchQuote',
        'BatchResponse',
        'BatchSummary',
        'File',
        'OpenBatchResponse',
        'PrintJob',
      ].sort(),
    );
  });

  it('parses every frozen batch snapshot, both timelines’ batches and the monthly close', () => {
    const batches = [
      ...V2_FIXTURE.batches,
      V2_FIXTURE.nextBatch.batch,
      V2_FIXTURE.rebatchedBatch.batch,
    ];
    for (const batch of batches) {
      const result = BatchResponseSchema.safeParse({ batch });
      expect(result.success, `${batch.status}: ${JSON.stringify(result.error?.issues)}`).toBe(true);
      expect(BatchSummarySchema.safeParse(summaryOf({ ...batch })).success).toBe(true);
    }
    expect(OpenBatchResponseSchema.safeParse({ batch: null }).success).toBe(true);
    expect(
      BatchListResponseSchema.safeParse({
        items: batches.map((b) => summaryOf({ ...b })),
        nextCursor: null,
      }).success,
    ).toBe(true);
    const close = CloseResponseSchema.safeParse(V2_FIXTURE.monthlyClose);
    expect(close.success, JSON.stringify(close.error?.issues)).toBe(true);
    expect(close.data?.close.items.map((i) => i.kind)).toEqual(['batch', 'legacy_order']);
  });

  it('refuses unknown fields, bad enums, float money and broken invariants', () => {
    const batch = structuredClone(V2_FIXTURE.batches[0]) as unknown as Record<string, unknown>;
    const parse = (b: unknown) => BatchResponseSchema.safeParse({ batch: b }).success;
    expect(parse({ ...batch, bucket: 'solicitations' })).toBe(false);
    expect(parse({ ...batch, status: 'ready' })).toBe(false);
    expect(parse({ ...batch, approvedAmountCents: 10.5 })).toBe(false);
    expect(parse({ ...batch, reference: 'IMP-0001' })).toBe(false);
    expect(parse({ ...batch, itemCount: 2 })).toBe(false);
    const items = batch.items as Record<string, unknown>[];
    const item = items[0] as Record<string, unknown>;
    expect(parse({ ...batch, items: [{ ...item, supplierEmail: 'x@y' }] })).toBe(false);
    expect(parse({ ...batch, items: [{ ...item, previouslyCancelledIn: 'IMP-0001' }] })).toBe(
      false,
    );
    expect(parse({ ...batch, items: [item, item], itemCount: 2 })).toBe(false);
    const jobs = item.jobs as Record<string, unknown>[];
    // The same file twice within one request, or a request without files.
    expect(
      parse({
        ...batch,
        items: [{ ...item, jobs: [jobs[0], jobs[0]], generalInstructions: undefined }],
      }),
    ).toBe(false);
    expect(
      parse({
        ...batch,
        items: [{ ...item, jobs: [], generalInstructions: { text: 'x', files: [] } }],
      }),
    ).toBe(false);
    const close = structuredClone(V2_FIXTURE.monthlyClose.close) as Record<string, unknown>;
    expect(
      CloseResponseSchema.safeParse({ close: { ...close, accountingSemesterId: 'x' } }).success,
    ).toBe(false);
    const [batchCharge] = close.items as Record<string, unknown>[];
    expect(
      CloseResponseSchema.safeParse({
        close: { ...close, items: [{ ...batchCharge, kind: 'legacy_order' }] },
      }).success,
    ).toBe(false);
    expect(
      ErrorSchema.safeParse({ error: { code: 'SQL_ERROR', message: 'x', requestId: 'r' } }).success,
    ).toBe(false);
    expect(
      ErrorSchema.safeParse({
        error: { code: 'BATCH_WORKFLOW_REQUIRED', message: 'x', requestId: 'r' },
      }).success,
    ).toBe(true);
  });
});
