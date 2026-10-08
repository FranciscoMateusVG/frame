import { createHash, randomUUID } from 'node:crypto';
import { type Span, SpanStatusCode, trace } from '@opentelemetry/api';
import {
  type CloseItem,
  competenceOf,
  isValidCompetence,
  type MonthlyClose,
} from '../domain/monthly-close.js';
import type {
  Order,
  OrderPage,
  OrderStatus,
  PrintFile,
  PrintJob,
  Quote,
} from '../domain/print-order.js';
import { UpstreamRejectedError } from '../errors/upstream-rejected.error.js';
import { markSpanFailed } from '../observability/span-errors.js';
import {
  type CommandResult,
  type Download,
  type ListOrdersQuery,
  PRINT_API_PREFIX,
  type Preconditions,
  type PrintApi,
  type Tagged,
  type Upload,
} from './print-api.js';

const tracer = trace.getTracer('frame');

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DOCUMENT_MAX_BYTES = 5 * 1024 * 1024;

const MESSAGES: Record<string, string> = {
  NOT_FOUND: 'Recurso não encontrado.',
  INVALID_REQUEST: 'Requisição inválida.',
  INVALID_CURSOR: 'Cursor inválido.',
  INVALID_COMPETENCE: 'Competência inválida.',
  INVALID_STATE: 'O pedido não está em um estado que permita esta operação.',
  IDEMPOTENCY_CONFLICT: 'A chave de idempotência já foi usada para outra operação.',
  VERSION_MISMATCH: 'O pedido foi atualizado. Consulte novamente antes de repetir.',
  PRECONDITION_REQUIRED: 'Cabeçalhos If-Match e Idempotency-Key são obrigatórios.',
  PERIOD_OPEN: 'A competência ainda não foi encerrada.',
  EMPTY_CLOSE: 'Não há pedidos impressos nesta competência.',
  FILE_TOO_LARGE: 'Arquivo acima de 5 MB.',
  UNSUPPORTED_MEDIA_TYPE: 'Formato de arquivo não aceito.',
};

const STATUS: Record<string, number> = {
  NOT_FOUND: 404,
  INVALID_REQUEST: 400,
  INVALID_CURSOR: 400,
  INVALID_COMPETENCE: 400,
  INVALID_STATE: 409,
  IDEMPOTENCY_CONFLICT: 409,
  PERIOD_OPEN: 409,
  EMPTY_CLOSE: 409,
  VERSION_MISMATCH: 412,
  PRECONDITION_REQUIRED: 428,
  FILE_TOO_LARGE: 413,
  UNSUPPORTED_MEDIA_TYPE: 415,
};

function reject(code: string): UpstreamRejectedError {
  return new UpstreamRejectedError(
    STATUS[code] ?? 400,
    code,
    MESSAGES[code] ?? code,
    `mem-${randomUUID()}`,
  );
}

/** Input for {@link PrintApiMemory.seedOrder}. */
export interface SeedJob {
  readonly title: string;
  readonly copies: number;
  readonly instructions: string;
  readonly file: { readonly name: string; readonly mime: string; readonly bytes: Uint8Array };
}

interface StoredOrder {
  order: Order;
  supplierId: string;
}

interface StoredClose {
  id: string;
  version: number;
  state: MonthlyClose['state'];
  items: CloseItem[];
  declaredTotalCents: number | null;
  document: PrintFile | null;
  rejectionReason: string | null;
  submittedAt: string | null;
  acceptedAt: string | null;
}

interface IdempotencyRecord {
  intent: string;
  result: CommandResult<unknown>;
}

export interface PrintApiMemoryOptions {
  /** Supplier this credential belongs to. Other suppliers' data is invisible (404). */
  readonly supplierId?: string;
  readonly clock?: () => Date;
}

/**
 * In-memory fake of the Incluir print-portal service API.
 *
 * Mirrors the upstream rules the portal depends on — supplier scoping
 * (foreign ids are 404), the order state machine, ETag/If-Match (412),
 * Idempotency-Key replay/conflict, 428 when preconditions are missing,
 * document type/size checks, keyset pagination and the monthly close —
 * following the check order of PR B's `print-order-service.ts`. The staff
 * side (approve/reject quote, cancel, accept/reject invoice) is exposed as
 * test helpers, since the portal never performs those.
 *
 * Instrumented identically to {@link PrintApiHttp}: same span names and
 * attributes, `server.address = "memory"`.
 */
export class PrintApiMemory implements PrintApi {
  private readonly orders = new Map<string, StoredOrder>();
  private readonly blobs = new Map<string, Uint8Array>();
  private readonly fileNames = new Map<string, string>();
  private readonly closes = new Map<string, StoredClose>();
  private readonly idempotency = new Map<string, IdempotencyRecord>();
  private sequence = 0;
  private readonly supplierId: string;
  private readonly clock: () => Date;

  constructor(options: PrintApiMemoryOptions = {}) {
    this.supplierId = options.supplierId ?? 'supplier-a';
    this.clock = options.clock ?? (() => new Date());
  }

  // ── test helpers (staff / seed side) ──

  /** Create a `ready` order. `supplierId` defaults to this credential's supplier. */
  seedOrder(input: {
    readonly title?: string;
    readonly jobs: readonly SeedJob[];
    readonly supplierId?: string;
  }): Order {
    this.sequence++;
    const now = this.clock().toISOString();
    const jobs: PrintJob[] = input.jobs.map((job) => ({
      id: randomUUID(),
      title: job.title,
      copies: job.copies,
      instructions: job.instructions,
      file: this.storeFile(job.file.name, job.file.mime, job.file.bytes),
    }));
    const order: Order = {
      id: randomUUID(),
      reference: `IMP-${String(this.sequence).padStart(4, '0')}`,
      title: input.title ?? jobs[0]?.title ?? 'Pedido',
      revision: 1,
      version: 1,
      status: 'ready',
      // Strictly increasing createdAt keeps keyset order deterministic.
      createdAt: new Date(Date.parse(now) + this.sequence).toISOString(),
      collectedAt: null,
      printedAt: null,
      approvedAmountCents: null,
      jobs,
      currentQuote: null,
      cancellationReason: null,
    };
    this.orders.set(order.id, { order, supplierId: input.supplierId ?? this.supplierId });
    return order;
  }

  /** Staff approves the current pending quote. */
  approveQuote(orderId: string): Order {
    return this.staffDecide(orderId, 'approved', null);
  }

  /** Staff rejects the current pending quote with a reason. */
  rejectQuote(orderId: string, reason: string): Order {
    return this.staffDecide(orderId, 'rejected', reason);
  }

  /** Staff cancels an order (any non-final state). */
  cancelOrder(orderId: string, reason: string): Order {
    const stored = this.mustGet(orderId);
    if (stored.order.status === 'printed' || stored.order.status === 'cancelled') {
      throw reject('INVALID_STATE');
    }
    return this.update(stored, { status: 'cancelled', cancellationReason: reason });
  }

  /** Staff accepts or rejects the submitted invoice of a competence. */
  decideInvoice(competence: string, decision: 'accepted' | 'rejected', reason?: string): void {
    const close = this.closes.get(competence);
    if (!close || close.state !== 'submitted') throw reject('INVALID_STATE');
    close.version++;
    if (decision === 'accepted') {
      close.state = 'accepted';
      close.acceptedAt = this.clock().toISOString();
    } else {
      close.state = 'rejected';
      close.rejectionReason = reason ?? 'Rejeitada';
    }
  }

  // ── PrintApi ──

  listOrders(query: ListOrdersQuery): Promise<OrderPage> {
    return this.span('listOrders', 'GET', '/orders', async () => {
      let after: { createdAt: string; id: string } | null = null;
      if (query.cursor !== undefined) {
        after = decodeCursor(query.cursor, query.status);
        if (!after) throw reject('INVALID_CURSOR');
      }
      const visible = [...this.orders.values()]
        .filter((s) => s.supplierId === this.supplierId)
        .map((s) => s.order)
        .filter((o) => !query.status || o.status === query.status)
        .sort((a, b) => a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id))
        .filter(
          (o) =>
            !after ||
            o.createdAt > after.createdAt ||
            (o.createdAt === after.createdAt && o.id > after.id),
        );
      const page = visible.slice(0, query.limit);
      const last = page[page.length - 1];
      return {
        items: page.map(summary),
        nextCursor: visible.length > query.limit && last ? encodeCursor(last, query.status) : null,
      };
    });
  }

  getOrder(orderId: string): Promise<Tagged<Order>> {
    return this.span('getOrder', 'GET', '/orders/:id', async () => {
      const { order } = this.visible(orderId);
      return { value: order, etag: etagOf(order.id, order.version) };
    });
  }

  downloadOrderFile(orderId: string, fileId: string): Promise<Download> {
    return this.span('downloadOrderFile', 'GET', '/orders/:id/files/:fileId', async () => {
      const { order } = this.visible(orderId);
      const job = order.jobs.find((j) => j.file.id === fileId);
      if (order.status === 'cancelled' || !job) throw reject('NOT_FOUND');
      return this.download(job.file);
    });
  }

  downloadQuoteFile(orderId: string, quoteId: string): Promise<Download> {
    return this.span('downloadQuoteFile', 'GET', '/orders/:id/quotes/:quoteId/file', async () => {
      const { order } = this.visible(orderId);
      if (order.currentQuote?.id !== quoteId) throw reject('NOT_FOUND');
      return this.download(order.currentQuote.document);
    });
  }

  markCollected(
    orderId: string,
    input: { readonly revision: number },
    pre: Preconditions,
  ): Promise<CommandResult<Order>> {
    return this.span('markCollected', 'POST', '/orders/:id/collected', async () =>
      this.orderCommand(orderId, pre, { revision: input.revision }, 200, (stored) => {
        const { order } = stored;
        if (order.status !== 'ready') throw reject('INVALID_STATE');
        if (input.revision !== order.revision) throw reject('VERSION_MISMATCH');
        return this.update(stored, {
          status: 'files_collected',
          collectedAt: this.clock().toISOString(),
        });
      }),
    );
  }

  submitQuote(
    orderId: string,
    input: { readonly amountCents: number; readonly orderRevision: number; readonly file: Upload },
    pre: Preconditions,
  ): Promise<CommandResult<Order>> {
    return this.span('submitQuote', 'POST', '/orders/:id/quotes', async () => {
      this.visible(orderId);
      const mime = documentMime(input.file.bytes);
      const fields = {
        amountCents: input.amountCents,
        orderRevision: input.orderRevision,
        file: sha256(input.file.bytes),
      };
      return this.orderCommand(orderId, pre, fields, 201, (stored) => {
        const { order } = stored;
        if (order.status !== 'files_collected' && order.status !== 'quote_rejected') {
          throw reject('INVALID_STATE');
        }
        if (input.orderRevision !== order.revision) throw reject('VERSION_MISMATCH');
        const previous = order.currentQuote?.revision ?? 0;
        const quote: Quote = {
          id: randomUUID(),
          revision: previous + 1,
          orderRevision: order.revision,
          amountCents: input.amountCents,
          currency: 'BRL',
          document: this.storeFile(input.file.filename, mime, input.file.bytes),
          decision: 'pending',
          rejectionReason: null,
          submittedAt: this.clock().toISOString(),
          decidedAt: null,
        };
        return this.update(stored, { status: 'quote_pending', currentQuote: quote });
      });
    });
  }

  markPrinted(
    orderId: string,
    input: { readonly revision: number; readonly quoteId: string },
    pre: Preconditions,
  ): Promise<CommandResult<Order>> {
    return this.span('markPrinted', 'POST', '/orders/:id/printed', async () =>
      this.orderCommand(
        orderId,
        pre,
        { revision: input.revision, quoteId: input.quoteId.toLowerCase() },
        200,
        (stored) => {
          const { order } = stored;
          const quote = order.currentQuote;
          if (order.status !== 'quote_approved' || quote?.decision !== 'approved') {
            throw reject('INVALID_STATE');
          }
          if (input.revision !== order.revision || input.quoteId !== quote.id) {
            throw reject('VERSION_MISMATCH');
          }
          const printedAt = this.clock().toISOString();
          this.bill(order, quote, printedAt);
          return this.update(stored, { status: 'printed', printedAt });
        },
      ),
    );
  }

  getMonthlyClose(competence: string): Promise<Tagged<MonthlyClose>> {
    return this.span('getMonthlyClose', 'GET', '/monthly-closes/:competence', async () => {
      if (!isValidCompetence(competence)) throw reject('INVALID_COMPETENCE');
      return this.closeView(competence);
    });
  }

  submitInvoice(
    competence: string,
    input: { readonly declaredTotalCents: number; readonly file: Upload },
    pre: Preconditions,
  ): Promise<CommandResult<MonthlyClose>> {
    return this.span('submitInvoice', 'POST', '/monthly-closes/:competence/invoice', async () => {
      if (!isValidCompetence(competence)) throw reject('INVALID_COMPETENCE');
      const mime = documentMime(input.file.bytes);
      const fields = {
        declaredTotalCents: input.declaredTotalCents,
        file: sha256(input.file.bytes),
      };
      return this.idempotent(`close:${competence}`, pre, fields, 201, () => {
        const current = this.closeView(competence);
        if (pre.ifMatch !== current.etag) throw reject('VERSION_MISMATCH');
        if (!current.value.periodClosed) throw reject('PERIOD_OPEN');
        const close = this.closes.get(competence);
        if (!close || close.items.length === 0) throw reject('EMPTY_CLOSE');
        if (close.state !== 'open' && close.state !== 'rejected') throw reject('INVALID_STATE');
        close.version++;
        close.state = 'submitted';
        close.declaredTotalCents = input.declaredTotalCents;
        close.document = this.storeFile(input.file.filename, mime, input.file.bytes);
        close.rejectionReason = null;
        close.submittedAt = this.clock().toISOString();
        return this.closeView(competence);
      });
    });
  }

  downloadInvoice(competence: string): Promise<Download> {
    return this.span('downloadInvoice', 'GET', '/monthly-closes/:competence/invoice', async () => {
      if (!isValidCompetence(competence)) throw reject('INVALID_COMPETENCE');
      const document = this.closes.get(competence)?.document;
      if (!document) throw reject('NOT_FOUND');
      return this.download(document);
    });
  }

  // ── internals ──

  private span<T>(
    operation: string,
    method: string,
    template: string,
    fn: (span: Span) => Promise<T>,
  ): Promise<T> {
    return tracer.startActiveSpan(`print_api.${operation}`, async (span) => {
      span.setAttribute('http.request.method', method);
      span.setAttribute('url.template', `${PRINT_API_PREFIX}${template}`);
      span.setAttribute('server.address', 'memory');
      span.setAttribute('print_api.operation', operation);
      try {
        const result = await fn(span);
        span.setStatus({ code: SpanStatusCode.OK });
        return result;
      } catch (error) {
        if (error instanceof UpstreamRejectedError) {
          span.setAttribute('print_api.error.code', error.code);
        }
        markSpanFailed(span, error);
        throw error;
      } finally {
        span.end();
      }
    });
  }

  private mustGet(orderId: string): StoredOrder {
    const stored = this.orders.get(orderId);
    if (!stored) throw reject('NOT_FOUND');
    return stored;
  }

  /** Lookup scoped to this credential's supplier: foreign ids are 404. */
  private visible(orderId: string): StoredOrder {
    if (!UUID_RE.test(orderId)) throw reject('NOT_FOUND');
    const stored = this.orders.get(orderId);
    if (!stored || stored.supplierId !== this.supplierId) throw reject('NOT_FOUND');
    return stored;
  }

  private update(stored: StoredOrder, patch: Partial<Order>): Order {
    const next: Order = { ...stored.order, ...patch, version: stored.order.version + 1 };
    stored.order = next;
    return next;
  }

  private staffDecide(
    orderId: string,
    decision: 'approved' | 'rejected',
    reason: string | null,
  ): Order {
    const stored = this.mustGet(orderId);
    const quote = stored.order.currentQuote;
    if (stored.order.status !== 'quote_pending' || quote?.decision !== 'pending') {
      throw reject('INVALID_STATE');
    }
    const decided: Quote = {
      ...quote,
      decision,
      rejectionReason: reason,
      decidedAt: this.clock().toISOString(),
    };
    return this.update(stored, {
      status: decision === 'approved' ? 'quote_approved' : 'quote_rejected',
      currentQuote: decided,
      approvedAmountCents: decision === 'approved' ? quote.amountCents : null,
    });
  }

  private orderCommand(
    orderId: string,
    pre: Preconditions,
    fields: Record<string, string | number>,
    status: 200 | 201,
    run: (stored: StoredOrder) => Order,
  ): CommandResult<Order> {
    const stored = this.visible(orderId);
    return this.idempotent(`order:${orderId}`, pre, fields, status, () => {
      const current = stored.order;
      if (pre.ifMatch !== etagOf(current.id, current.version)) throw reject('VERSION_MISMATCH');
      const next = run(stored);
      return { value: next, etag: etagOf(next.id, next.version) };
    });
  }

  private idempotent<T>(
    resource: string,
    pre: Preconditions,
    fields: Record<string, string | number>,
    status: 200 | 201,
    run: () => Tagged<T>,
  ): CommandResult<T> {
    if (!pre.ifMatch || !pre.idempotencyKey) throw reject('PRECONDITION_REQUIRED');
    if (!UUID_RE.test(pre.idempotencyKey)) throw reject('INVALID_REQUEST');
    const key = pre.idempotencyKey.toLowerCase();
    const intent = JSON.stringify({ resource, ifMatch: pre.ifMatch, fields });
    const seen = this.idempotency.get(key);
    if (seen) {
      if (seen.intent !== intent) throw reject('IDEMPOTENCY_CONFLICT');
      return { ...(seen.result as CommandResult<T>), replayed: true };
    }
    const tagged = run();
    const result: CommandResult<T> = { ...tagged, status, replayed: false };
    this.idempotency.set(key, { intent, result });
    return result;
  }

  private storeFile(name: string, mime: string, bytes: Uint8Array): PrintFile {
    const id = randomUUID();
    this.blobs.set(id, bytes);
    this.fileNames.set(id, name);
    return { id, name, mime, bytes: bytes.byteLength, sha256: sha256(bytes) };
  }

  private download(file: PrintFile): Download {
    const bytes = this.blobs.get(file.id) ?? new Uint8Array();
    return {
      filename: file.name,
      mime: file.mime,
      size: bytes.byteLength,
      body: new ReadableStream({
        start(controller) {
          controller.enqueue(bytes);
          controller.close();
        },
      }),
    };
  }

  private bill(order: Order, quote: Quote, printedAt: string): void {
    const competence = competenceOf(new Date(printedAt));
    let close = this.closes.get(competence);
    if (!close) {
      close = {
        id: randomUUID(),
        version: 0,
        state: 'open',
        items: [],
        declaredTotalCents: null,
        document: null,
        rejectionReason: null,
        submittedAt: null,
        acceptedAt: null,
      };
      this.closes.set(competence, close);
    }
    close.items.push({
      orderId: order.id,
      reference: order.reference,
      quoteId: quote.id,
      amountCents: quote.amountCents,
      printedAt,
    });
    close.version++;
  }

  private closeView(competence: string): Tagged<MonthlyClose> {
    const periodClosed = competence < competenceOf(this.clock());
    const close = this.closes.get(competence);
    if (!close) {
      return {
        value: {
          id: null,
          competence,
          version: 0,
          state: 'open',
          periodClosed,
          items: [],
          expectedTotalCents: 0,
          declaredTotalCents: null,
          document: null,
          rejectionReason: null,
          submittedAt: null,
          acceptedAt: null,
        },
        etag: `"month:${competence}:0"`,
      };
    }
    return {
      value: {
        id: close.id,
        competence,
        version: close.version,
        state: close.state,
        periodClosed,
        items: [...close.items],
        expectedTotalCents: close.items.reduce((sum, i) => sum + i.amountCents, 0),
        declaredTotalCents: close.declaredTotalCents,
        document: close.document,
        rejectionReason: close.rejectionReason,
        submittedAt: close.submittedAt,
        acceptedAt: close.acceptedAt,
      },
      etag: etagOf(close.id, close.version),
    };
  }
}

function etagOf(id: string, version: number): string {
  return `"${id}:${version}"`;
}

function summary(order: Order) {
  return {
    id: order.id,
    reference: order.reference,
    title: order.title,
    revision: order.revision,
    version: order.version,
    status: order.status,
    createdAt: order.createdAt,
    collectedAt: order.collectedAt,
    printedAt: order.printedAt,
    approvedAmountCents: order.approvedAmountCents,
  };
}

function encodeCursor(order: Order, status: OrderStatus | undefined): string {
  return Buffer.from(JSON.stringify([order.createdAt, order.id, status ?? null])).toString(
    'base64url',
  );
}

function decodeCursor(
  cursor: string,
  status: OrderStatus | undefined,
): { createdAt: string; id: string } | null {
  try {
    const parsed: unknown = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8'));
    if (
      Array.isArray(parsed) &&
      typeof parsed[0] === 'string' &&
      typeof parsed[1] === 'string' &&
      parsed[2] === (status ?? null)
    ) {
      return { createdAt: parsed[0], id: parsed[1] };
    }
  } catch {
    // fall through
  }
  return null;
}

function sha256(bytes: Uint8Array): string {
  return createHash('sha256').update(bytes).digest('hex');
}

/** Magic-byte detection, as upstream: PDF/JPEG/PNG/WebP only, ≤ 5 MiB. */
function documentMime(bytes: Uint8Array): string {
  if (bytes.byteLength > DOCUMENT_MAX_BYTES) throw reject('FILE_TOO_LARGE');
  const head = Buffer.from(bytes.subarray(0, 12));
  if (head.subarray(0, 5).toString('latin1') === '%PDF-') return 'application/pdf';
  if (head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) return 'image/jpeg';
  if (head.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) {
    return 'image/png';
  }
  if (
    head.subarray(0, 4).toString('latin1') === 'RIFF' &&
    head.subarray(8, 12).toString('latin1') === 'WEBP'
  ) {
    return 'image/webp';
  }
  throw reject('UNSUPPORTED_MEDIA_TYPE');
}
