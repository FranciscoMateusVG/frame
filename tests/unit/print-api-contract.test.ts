/**
 * The Zod mirror in src/adapters/print-api.contract.ts against the FROZEN
 * contract copied verbatim from monorepo-incluir (PR B #1038 + PR C):
 * every captured fixture body must parse, every $def must have a mirror,
 * and the mirror must refuse what the schema refuses.
 */
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  CloseResponseSchema,
  ErrorSchema,
  OrderListResponseSchema,
  OrderResponseSchema,
} from '../../src/adapters/print-api.contract.js';

const load = (name: string) =>
  JSON.parse(readFileSync(new URL(`../helpers/${name}`, import.meta.url), 'utf8')) as Record<
    string,
    unknown
  >;

const schema = load('print-portal-v1.schema.json') as { $defs: Record<string, unknown> };
const orders = load('print-portal-v1.fixture.json');
const closes = load('print-portal-v1.monthly-closes.fixture.json') as {
  bodies: Record<string, unknown>;
  etags: Record<string, string>;
};

describe('frozen print-portal v1 contract', () => {
  it('mirrors every $def of the JSON Schema', () => {
    expect(Object.keys(schema.$defs).sort()).toEqual(
      [
        'Close',
        'CloseItem',
        'CloseResponse',
        'Error',
        'File',
        'Order',
        'OrderListResponse',
        'OrderResponse',
        'OrderSummary',
        'PrintJob',
        'Quote',
      ].sort(),
    );
  });

  it('parses every captured order body', () => {
    for (const [name, body] of Object.entries(orders)) {
      const parser = name.startsWith('error')
        ? ErrorSchema
        : name === 'GET /orders'
          ? OrderListResponseSchema
          : OrderResponseSchema;
      const result = parser.safeParse(body);
      expect(result.success, `${name}: ${JSON.stringify(result.error?.issues)}`).toBe(true);
    }
  });

  it('parses every captured monthly-close body and its ETag shape', () => {
    for (const [name, body] of Object.entries(closes.bodies)) {
      const result = CloseResponseSchema.safeParse(body);
      expect(result.success, `${name}: ${JSON.stringify(result.error?.issues)}`).toBe(true);
    }
    for (const etag of Object.values(closes.etags)) {
      expect(etag).toMatch(/^"(month:\d{4}-\d{2}:0|[0-9a-f-]{36}:\d+)"$/);
    }
  });

  it('refuses unknown fields, bad enums and float money (additionalProperties:false)', () => {
    const order = (orders['GET /orders/:id (ready)'] as { order: Record<string, unknown> }).order;
    expect(
      OrderResponseSchema.safeParse({ order: { ...order, bucket: 'solicitations' } }).success,
    ).toBe(false);
    expect(
      OrderResponseSchema.safeParse({ order: { ...order, status: 'needs_review' } }).success,
    ).toBe(false);
    expect(
      OrderResponseSchema.safeParse({ order: { ...order, approvedAmountCents: 10.5 } }).success,
    ).toBe(false);
    expect(OrderResponseSchema.safeParse({ order: { ...order, jobs: [] } }).success).toBe(false);
    const close = (
      closes.bodies['GET /monthly-closes/:competence (open, period closed)'] as { close: object }
    ).close;
    expect(
      CloseResponseSchema.safeParse({ close: { ...close, accountingSemesterId: 'x' } }).success,
    ).toBe(false);
    expect(
      ErrorSchema.safeParse({ error: { code: 'SQL_ERROR', message: 'x', requestId: 'r' } }).success,
    ).toBe(false);
  });
});
