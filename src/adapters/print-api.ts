import type { MonthlyClose } from '../domain/monthly-close.js';
import type { Order, OrderPage, OrderStatus } from '../domain/print-order.js';

/** Path prefix of the service API on the Incluir origin. */
export const PRINT_API_PREFIX = '/api/print-portal/v1';

/**
 * PrintApi — the port to the Incluir print-portal service API
 * (`/api/print-portal/v1`, spec §4.3, frozen schema print-portal-v1).
 *
 * The real adapter holds the service token; nothing here ever receives a
 * token, a URL or a host from the caller. Every method either resolves with
 * contract data or rejects with:
 *  - `UpstreamRejectedError` — the API answered with a contract error
 *    (status + code), e.g. 404 NOT_FOUND, 409 INVALID_STATE, 412, 428, 429;
 *  - `UpstreamUnavailableError` — anything that is not a usable contract
 *    answer (timeout, network, 5xx, redirect, malformed body, 401/503 from
 *    a bad or missing service token).
 */
export interface PrintApi {
  listOrders(query: ListOrdersQuery): Promise<OrderPage>;
  getOrder(orderId: string): Promise<Tagged<Order>>;
  downloadOrderFile(orderId: string, fileId: string): Promise<Download>;
  downloadQuoteFile(orderId: string, quoteId: string): Promise<Download>;
  markCollected(
    orderId: string,
    input: { readonly revision: number },
    pre: Preconditions,
  ): Promise<CommandResult<Order>>;
  submitQuote(
    orderId: string,
    input: { readonly amountCents: number; readonly orderRevision: number; readonly file: Upload },
    pre: Preconditions,
  ): Promise<CommandResult<Order>>;
  markPrinted(
    orderId: string,
    input: { readonly revision: number; readonly quoteId: string },
    pre: Preconditions,
  ): Promise<CommandResult<Order>>;
  getMonthlyClose(competence: string): Promise<Tagged<MonthlyClose>>;
  submitInvoice(
    competence: string,
    input: { readonly declaredTotalCents: number; readonly file: Upload },
    pre: Preconditions,
  ): Promise<CommandResult<MonthlyClose>>;
  downloadInvoice(competence: string): Promise<Download>;
}

export interface ListOrdersQuery {
  readonly status?: OrderStatus;
  readonly limit: number;
  readonly cursor?: string;
}

/** A resource together with its ETag (`"<id>:<version>"`). */
export interface Tagged<T> {
  readonly value: T;
  readonly etag: string;
}

/** Outcome of an accepted command. */
export interface CommandResult<T> extends Tagged<T> {
  readonly status: 200 | 201;
  /** True when the API replayed the original answer for a repeated key. */
  readonly replayed: boolean;
}

/** Optimistic-concurrency + idempotency headers, relayed verbatim. */
export interface Preconditions {
  readonly ifMatch?: string;
  readonly idempotencyKey?: string;
}

/** A single uploaded document (quote or invoice). */
export interface Upload {
  readonly filename: string;
  readonly bytes: Uint8Array;
}

/** A streamed download. The body is consumed at most once. */
export interface Download {
  readonly filename: string;
  readonly mime: string;
  readonly size: number;
  readonly body: ReadableStream<Uint8Array>;
}
