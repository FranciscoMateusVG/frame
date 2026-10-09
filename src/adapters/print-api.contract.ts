/**
 * Zod mirror of the FROZEN service contract
 * `apps/hono-app/docs/contracts/print-portal-v2.schema.json`
 * (monorepo-incluir #1053, re-freeze 27022467: batches + monthly closes).
 *
 * Every object is `.strict()` (= `additionalProperties: false`), so an
 * upstream field the contract does not name — a bucket, a key, an email —
 * fails parsing and never reaches the browser. The copy of the JSON Schema
 * and the frozen fixture in tests/helpers are checked against these
 * schemas by tests/unit/print-api-contract.test.ts.
 */
import { z } from 'zod';
import { CLOSE_STATES } from '../domain/monthly-close.js';
import { BATCH_STATUSES, QUOTE_DECISIONS } from '../domain/print-batch.js';

const MAX_SAFE = Number.MAX_SAFE_INTEGER;
const MAX_CENTS = 2_147_483_647;

const uuid = z
  .string()
  .regex(
    /^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}|00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$/,
  );
const instant = z.iso.datetime();
const positive = z.number().int().min(1).max(MAX_SAFE);
const cents = z.number().int().min(1).max(MAX_CENTS);
const orderReference = z.string().regex(/^IMP-\d{4,}$/);
const batchReference = z.string().regex(/^LOT-\d{4,}$/);

export const FileSchema = z
  .object({
    id: uuid,
    name: z.string().min(1).max(200),
    mime: z.string().min(1),
    bytes: positive,
    sha256: z.string().regex(/^[0-9a-f]{64}$/),
  })
  .strict();

export const PrintJobSchema = z
  .object({
    id: uuid,
    title: z.string().min(2).max(160),
    copies: z.number().int().min(1).max(500),
    instructions: z.string().min(5).max(4000),
    file: FileSchema,
  })
  .strict();

export const BatchItemSchema = z
  .object({
    orderId: uuid,
    previouslyCancelledIn: batchReference.optional(),
    reference: orderReference,
    title: z.string().min(1),
    revision: positive,
    jobs: z.array(PrintJobSchema),
    generalInstructions: z
      .object({ text: z.string(), files: z.array(FileSchema) })
      .strict()
      .optional(),
  })
  .strict()
  .refine(
    (item) => {
      // Each file appears exactly once within the item; at least one file.
      const ids = [
        ...item.jobs.map((j) => j.file.id),
        ...(item.generalInstructions?.files ?? []).map((f) => f.id),
      ];
      return ids.length > 0 && new Set(ids).size === ids.length;
    },
    { message: 'Each item needs at least one file, each exactly once', path: ['jobs'] },
  );

export const QuoteSchema = z
  .object({
    id: uuid,
    revision: positive,
    amountCents: cents,
    currency: z.literal('BRL'),
    document: FileSchema,
    decision: z.enum(QUOTE_DECISIONS),
    rejectionReason: z.string().nullable(),
    submittedAt: instant,
    decidedAt: instant.nullable(),
  })
  .strict();

const batchSummaryShape = {
  id: uuid,
  reference: batchReference,
  status: z.enum(BATCH_STATUSES),
  version: positive,
  itemCount: z.number().int().min(0).max(MAX_SAFE),
  createdAt: instant,
  collectedAt: instant.nullable(),
  printedAt: instant.nullable(),
  receivedAt: instant.nullable(),
  approvedAmountCents: cents.nullable(),
};

export const BatchSummarySchema = z.object(batchSummaryShape).strict();

export const BatchSchema = z
  .object({
    ...batchSummaryShape,
    items: z.array(BatchItemSchema),
    currentQuote: QuoteSchema.nullable(),
    cancellationReason: z.string().nullable(),
  })
  .strict()
  .refine(
    (batch) =>
      batch.itemCount === batch.items.length &&
      new Set(batch.items.map((i) => i.orderId)).size === batch.items.length,
    { message: 'itemCount equals items length; unique orderId', path: ['items'] },
  );

export const BatchResponseSchema = z.object({ batch: BatchSchema }).strict();

export const OpenBatchResponseSchema = z.object({ batch: BatchSchema.nullable() }).strict();

export const BatchListResponseSchema = z
  .object({ items: z.array(BatchSummarySchema), nextCursor: z.string().nullable() })
  .strict();

const closeCharge = {
  reference: z.string(),
  quoteId: uuid,
  amountCents: cents,
  printedAt: instant,
};

export const CloseItemSchema = z.discriminatedUnion('kind', [
  z.object({ ...closeCharge, kind: z.literal('batch'), batchId: uuid }).strict(),
  z.object({ ...closeCharge, kind: z.literal('legacy_order'), orderId: uuid }).strict(),
]);

export const CloseSchema = z
  .object({
    id: uuid.nullable(),
    competence: z.string().regex(/^[0-9]{4}-(0[1-9]|1[0-2])$/),
    version: z.number().int().min(0).max(MAX_SAFE),
    state: z.enum(CLOSE_STATES),
    periodClosed: z.boolean(),
    items: z.array(CloseItemSchema),
    expectedTotalCents: z.number().int().min(0).max(MAX_CENTS),
    declaredTotalCents: cents.nullable(),
    document: FileSchema.nullable(),
    rejectionReason: z.string().nullable(),
    submittedAt: instant.nullable(),
    acceptedAt: instant.nullable(),
  })
  .strict();

export const CloseResponseSchema = z.object({ close: CloseSchema }).strict();

export const ERROR_CODES = [
  'INVALID_REQUEST',
  'INVALID_CURSOR',
  'INVALID_COMPETENCE',
  'UNAUTHORIZED',
  'NOT_FOUND',
  'METHOD_NOT_ALLOWED',
  'INVALID_STATE',
  'IDEMPOTENCY_CONFLICT',
  'OPERATION_IN_PROGRESS',
  'PERIOD_OPEN',
  'EMPTY_CLOSE',
  'VERSION_MISMATCH',
  'FILE_TOO_LARGE',
  'UNSUPPORTED_MEDIA_TYPE',
  'PRECONDITION_REQUIRED',
  'RATE_LIMITED',
  'INTERNAL',
  'NOT_CONFIGURED',
  'UPSTREAM_UNAVAILABLE',
  'BATCH_NOT_ACTIVE',
  'BATCH_WORKFLOW_REQUIRED',
  'EMPTY_BATCH',
  'TOTAL_MISMATCH',
] as const;

export const ErrorSchema = z
  .object({
    error: z
      .object({ code: z.enum(ERROR_CODES), message: z.string(), requestId: z.string() })
      .strict(),
  })
  .strict();
