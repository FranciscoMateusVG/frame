/**
 * Zod mirror of the FROZEN service contract
 * `apps/hono-app/docs/contracts/print-portal-v1.schema.json`
 * (monorepo-incluir PR B #1038 + PR C monthly closes, 12178459).
 *
 * Every object is `.strict()` (= `additionalProperties: false`), so an
 * upstream field the contract does not name — a bucket, a key, an email —
 * fails parsing and never reaches the browser. The copy of the JSON Schema
 * and the captured fixtures in tests/helpers are checked against these
 * schemas by tests/unit/print-api-contract.test.ts.
 */
import { z } from 'zod';
import { CLOSE_STATES } from '../domain/monthly-close.js';
import { ORDER_STATUSES, QUOTE_DECISIONS } from '../domain/print-order.js';

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
const reference = z.string().regex(/^IMP-\d{4,}$/);

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

export const QuoteSchema = z
  .object({
    id: uuid,
    revision: positive,
    orderRevision: positive,
    amountCents: cents,
    currency: z.literal('BRL'),
    document: FileSchema,
    decision: z.enum(QUOTE_DECISIONS),
    rejectionReason: z.string().nullable(),
    submittedAt: instant,
    decidedAt: instant.nullable(),
  })
  .strict();

const orderSummaryShape = {
  id: uuid,
  reference,
  title: z.string().min(1),
  revision: positive,
  version: positive,
  status: z.enum(ORDER_STATUSES),
  createdAt: instant,
  collectedAt: instant.nullable(),
  printedAt: instant.nullable(),
  approvedAmountCents: cents.nullable(),
};

export const OrderSummarySchema = z.object(orderSummaryShape).strict();

export const OrderSchema = z
  .object({
    ...orderSummaryShape,
    jobs: z.array(PrintJobSchema).min(1),
    currentQuote: QuoteSchema.nullable(),
    cancellationReason: z.string().nullable(),
  })
  .strict();

export const OrderListResponseSchema = z
  .object({ items: z.array(OrderSummarySchema), nextCursor: z.string().nullable() })
  .strict();

export const OrderResponseSchema = z.object({ order: OrderSchema }).strict();

export const CloseItemSchema = z
  .object({ orderId: uuid, reference, quoteId: uuid, amountCents: cents, printedAt: instant })
  .strict();

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
] as const;

export const ErrorSchema = z
  .object({
    error: z
      .object({ code: z.enum(ERROR_CODES), message: z.string(), requestId: z.string() })
      .strict(),
  })
  .strict();
