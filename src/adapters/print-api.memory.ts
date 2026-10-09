import { createHash, randomUUID } from 'node:crypto';
import { type Span, SpanStatusCode, trace } from '@opentelemetry/api';
import { sniffDocumentMime } from '../domain/document-type.js';
import {
  type CloseItem,
  competenceOf,
  isValidCompetence,
  type MonthlyClose,
} from '../domain/monthly-close.js';
import type {
  Batch,
  BatchItem,
  BatchPage,
  BatchStatus,
  PrintFile,
  PrintJob,
  Quote,
} from '../domain/print-batch.js';
import { UpstreamRejectedError } from '../errors/upstream-rejected.error.js';
import { markSpanFailed } from '../observability/span-errors.js';
import {
  type CommandResult,
  type Download,
  type ListBatchesQuery,
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
  INVALID_STATE: 'O lote não está em um estado que permita esta operação.',
  EMPTY_BATCH: 'O lote está vazio.',
  IDEMPOTENCY_CONFLICT: 'A chave de idempotência já foi usada para outra operação.',
  VERSION_MISMATCH: 'O lote foi atualizado. Consulte novamente antes de repetir.',
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
  EMPTY_BATCH: 409,
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

/** A file given to a seed helper. */
export interface SeedFile {
  readonly name: string;
  readonly mime: string;
  readonly bytes: Uint8Array;
}

/** Input for {@link PrintApiMemory.publishRequest}. */
export interface SeedJob {
  readonly title: string;
  readonly copies: number;
  readonly instructions: string;
  readonly file: SeedFile;
}

interface StoredBatch {
  batch: Batch;
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

const CURRENT: readonly BatchStatus[] = [
  'open',
  'files_collected',
  'quote_pending',
  'quote_rejected',
  'quote_approved',
  'printed',
];

/**
 * In-memory fake of the Incluir print-portal v2 (batch) service API.
 *
 * Mirrors the upstream rules the portal depends on — supplier scoping
 * (foreign ids are 404), at most ONE current batch per supplier, the batch
 * state machine, ETag/If-Match (412), Idempotency-Key replay/conflict, 428
 * when preconditions are missing, document type/size checks, keyset
 * pagination and the monthly close. New requests published while a batch
 * is active are queued and only exposed in the next batch (after receipt or
 * cancellation). The staff side (approve/reject quote, receive, cancel,
 * accept/reject invoice) is exposed as test helpers, since the portal never
 * performs those.
 *
 * Instrumented identically to {@link PrintApiHttp}: same span names and
 * attributes, `server.address = "memory"`.
 */
export class PrintApiMemory implements PrintApi {
  private readonly batches = new Map<string, StoredBatch>();
  private readonly queued = new Map<string, BatchItem[]>();
  private readonly blobs = new Map<string, Uint8Array>();
  private readonly closes = new Map<string, StoredClose>();
  private readonly idempotency = new Map<string, IdempotencyRecord>();
  private orderSequence = 0;
  private batchSequence = 0;
  private readonly supplierId: string;
  private readonly clock: () => Date;

  constructor(options: PrintApiMemoryOptions = {}) {
    this.supplierId = options.supplierId ?? 'supplier-a';
    this.clock = options.clock ?? (() => new Date());
  }

  // ── test helpers (Incluir / staff side) ──

  /**
   * Publish a pending request. It joins the supplier's open batch (a new one
   * if there is none), or waits in the queue while a batch is active.
   */
  publishRequest(input: {
    readonly title?: string;
    readonly jobs: readonly SeedJob[];
    readonly generalInstructions?: { readonly text: string; readonly files: readonly SeedFile[] };
    readonly supplierId?: string;
  }): BatchItem {
    this.orderSequence++;
    const jobs: PrintJob[] = input.jobs.map((job) => ({
      id: randomUUID(),
      title: job.title,
      copies: job.copies,
      instructions: job.instructions,
      file: this.storeFile(job.file.name, job.file.mime, job.file.bytes),
    }));
    const general = input.generalInstructions;
    const item: BatchItem = {
      orderId: randomUUID(),
      reference: `IMP-${String(this.orderSequence).padStart(4, '0')}`,
      title: input.title ?? jobs[0]?.title ?? 'Solicitação',
      revision: 1,
      jobs,
      ...(general
        ? {
            generalInstructions: {
              text: general.text,
              files: general.files.map((f) => this.storeFile(f.name, f.mime, f.bytes)),
            },
          }
        : {}),
    };
    const supplierId = input.supplierId ?? this.supplierId;
    const current = this.currentOf(supplierId);
    if (current && current.batch.status !== 'open') {
      this.queued.set(supplierId, [...(this.queued.get(supplierId) ?? []), item]);
    } else if (current) {
      this.update(current, { items: [...current.batch.items, item] });
    } else {
      this.createBatch(supplierId, [item]);
    }
    return item;
  }

  /**
   * Store a batch verbatim (e.g. a frozen contract fixture snapshot) with
   * the bytes of every file it references, keyed by file id.
   */
  seedBatch(batch: Batch, files: ReadonlyMap<string, Uint8Array>, supplierId?: string): void {
    const documents = [
      ...batch.items.flatMap((item) => [
        ...item.jobs.map((j) => j.file),
        ...(item.generalInstructions?.files ?? []),
      ]),
      ...(batch.currentQuote ? [batch.currentQuote.document] : []),
    ];
    for (const file of documents) {
      const bytes = files.get(file.id);
      if (!bytes) throw new Error(`missing bytes for file ${file.id}`);
      this.blobs.set(file.id, bytes);
    }
    this.batchSequence++;
    this.batches.set(batch.id, { batch, supplierId: supplierId ?? this.supplierId });
  }

  /** Staff approves the current pending quote. */
  approveQuote(batchId: string): Batch {
    return this.staffDecide(batchId, 'approved', null);
  }

  /** Staff rejects the current pending quote with a reason. */
  rejectQuote(batchId: string, reason: string): Batch {
    return this.staffDecide(batchId, 'rejected', reason);
  }

  /** Financeiro confirms receipt of a printed batch; queued requests form the next batch. */
  receiveBatch(batchId: string): Batch {
    const stored = this.mustGet(batchId);
    if (stored.batch.status !== 'printed') throw reject('INVALID_STATE');
    const received = this.update(stored, {
      status: 'received',
      receivedAt: this.clock().toISOString(),
    });
    this.formNext(stored.supplierId, []);
    return received;
  }

  /**
   * Whole-batch cancellation (before printed): every member returns to the
   * next open batch, flagged with this batch's reference, with any queued
   * requests. No quote is transferred.
   */
  cancelBatch(batchId: string, reason: string): Batch {
    const stored = this.mustGet(batchId);
    if (!CURRENT.includes(stored.batch.status) || stored.batch.status === 'printed') {
      throw reject('INVALID_STATE');
    }
    const cancelled = this.update(stored, { status: 'cancelled', cancellationReason: reason });
    const members = cancelled.items.map((item) => ({
      ...item,
      previouslyCancelledIn: cancelled.reference,
    }));
    this.formNext(stored.supplierId, members);
    return cancelled;
  }

  /** A historical individual (pre-batch) charge in the monthly close. */
  seedLegacyCharge(input: {
    readonly reference: string;
    readonly amountCents: number;
    readonly printedAt: string;
  }): void {
    this.charge(input.printedAt, {
      kind: 'legacy_order',
      orderId: randomUUID(),
      reference: input.reference,
      quoteId: randomUUID(),
      amountCents: input.amountCents,
      printedAt: input.printedAt,
    });
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

  listBatches(query: ListBatchesQuery): Promise<BatchPage> {
    return this.span('listBatches', 'GET', '/batches', async () => {
      let after: { createdAt: string; id: string } | null = null;
      if (query.cursor !== undefined) {
        after = decodeCursor(query.cursor, query.status);
        if (!after) throw reject('INVALID_CURSOR');
      }
      const visible = [...this.batches.values()]
        .filter((s) => s.supplierId === this.supplierId)
        .map((s) => s.batch)
        .filter((b) => !query.status || b.status === query.status)
        .sort((a, b) => a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id))
        .filter(
          (b) =>
            !after ||
            b.createdAt > after.createdAt ||
            (b.createdAt === after.createdAt && b.id > after.id),
        );
      const page = visible.slice(0, query.limit);
      const last = page[page.length - 1];
      return {
        items: page.map(summary),
        nextCursor: visible.length > query.limit && last ? encodeCursor(last, query.status) : null,
      };
    });
  }

  getOpenBatch(): Promise<Tagged<Batch> | null> {
    return this.span('getOpenBatch', 'GET', '/batches/open', async () => {
      const current = this.currentOf(this.supplierId);
      if (!current || current.batch.status !== 'open') return null;
      return { value: current.batch, etag: etagOf(current.batch) };
    });
  }

  getBatch(batchId: string): Promise<Tagged<Batch>> {
    return this.span('getBatch', 'GET', '/batches/:id', async () => {
      const { batch } = this.visible(batchId);
      return { value: batch, etag: etagOf(batch) };
    });
  }

  downloadBatchFile(batchId: string, orderId: string, fileId: string): Promise<Download> {
    return this.span(
      'downloadBatchFile',
      'GET',
      '/batches/:id/orders/:orderId/files/:fileId',
      async () => {
        const { batch } = this.visible(batchId);
        const item = batch.items.find((i) => i.orderId === orderId);
        const file = item
          ? [...item.jobs.map((j) => j.file), ...(item.generalInstructions?.files ?? [])].find(
              (f) => f.id === fileId,
            )
          : undefined;
        if (!file) throw reject('NOT_FOUND');
        return this.download(file);
      },
    );
  }

  downloadQuoteFile(batchId: string, quoteId: string): Promise<Download> {
    return this.span('downloadQuoteFile', 'GET', '/batches/:id/quotes/:quoteId/file', async () => {
      const { batch } = this.visible(batchId);
      if (batch.currentQuote?.id !== quoteId) throw reject('NOT_FOUND');
      return this.download(batch.currentQuote.document);
    });
  }

  markCollected(batchId: string, pre: Preconditions): Promise<CommandResult<Batch>> {
    return this.span('markCollected', 'POST', '/batches/:id/collected', async () =>
      this.batchCommand(batchId, pre, {}, 200, (stored) => {
        if (stored.batch.status !== 'open') throw reject('INVALID_STATE');
        if (stored.batch.items.length === 0) throw reject('EMPTY_BATCH');
        return this.update(stored, {
          status: 'files_collected',
          collectedAt: this.clock().toISOString(),
        });
      }),
    );
  }

  submitQuote(
    batchId: string,
    input: { readonly amountCents: number; readonly file: Upload },
    pre: Preconditions,
  ): Promise<CommandResult<Batch>> {
    return this.span('submitQuote', 'POST', '/batches/:id/quotes', async () => {
      this.visible(batchId);
      const mime = documentMime(input.file.bytes);
      const fields = { amountCents: input.amountCents, file: sha256(input.file.bytes) };
      return this.batchCommand(batchId, pre, fields, 201, (stored) => {
        const { batch } = stored;
        if (batch.status !== 'files_collected' && batch.status !== 'quote_rejected') {
          throw reject('INVALID_STATE');
        }
        const quote: Quote = {
          id: randomUUID(),
          revision: (batch.currentQuote?.revision ?? 0) + 1,
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
    batchId: string,
    input: { readonly quoteId: string },
    pre: Preconditions,
  ): Promise<CommandResult<Batch>> {
    return this.span('markPrinted', 'POST', '/batches/:id/printed', async () =>
      this.batchCommand(batchId, pre, { quoteId: input.quoteId.toLowerCase() }, 200, (stored) => {
        const { batch } = stored;
        const quote = batch.currentQuote;
        if (batch.status !== 'quote_approved' || quote?.decision !== 'approved') {
          throw reject('INVALID_STATE');
        }
        if (input.quoteId !== quote.id) throw reject('VERSION_MISMATCH');
        const printedAt = this.clock().toISOString();
        this.charge(printedAt, {
          kind: 'batch',
          batchId: batch.id,
          reference: batch.reference,
          quoteId: quote.id,
          amountCents: quote.amountCents,
          printedAt,
        });
        return this.update(stored, { status: 'printed', printedAt });
      }),
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

  private mustGet(batchId: string): StoredBatch {
    const stored = this.batches.get(batchId);
    if (!stored) throw reject('NOT_FOUND');
    return stored;
  }

  /** Lookup scoped to this credential's supplier: foreign ids are 404. */
  private visible(batchId: string): StoredBatch {
    if (!UUID_RE.test(batchId)) throw reject('NOT_FOUND');
    const stored = this.batches.get(batchId);
    if (!stored || stored.supplierId !== this.supplierId) throw reject('NOT_FOUND');
    return stored;
  }

  /** The supplier's one current (open through printed) batch, if any. */
  private currentOf(supplierId: string): StoredBatch | undefined {
    return [...this.batches.values()].find(
      (s) => s.supplierId === supplierId && CURRENT.includes(s.batch.status),
    );
  }

  private createBatch(supplierId: string, items: readonly BatchItem[]): void {
    this.batchSequence++;
    const now = this.clock().toISOString();
    const batch: Batch = {
      id: randomUUID(),
      reference: `LOT-${String(this.batchSequence).padStart(4, '0')}`,
      status: 'open',
      version: 1,
      itemCount: items.length,
      // Strictly increasing createdAt keeps keyset order deterministic.
      createdAt: new Date(Date.parse(now) + this.batchSequence).toISOString(),
      collectedAt: null,
      printedAt: null,
      receivedAt: null,
      approvedAmountCents: null,
      items,
      currentQuote: null,
      cancellationReason: null,
    };
    this.batches.set(batch.id, { batch, supplierId });
  }

  /** Next open batch: returning members first, then the queued requests. */
  private formNext(supplierId: string, members: readonly BatchItem[]): void {
    const items = [...members, ...(this.queued.get(supplierId) ?? [])];
    this.queued.delete(supplierId);
    if (items.length > 0) this.createBatch(supplierId, items);
  }

  private update(stored: StoredBatch, patch: Partial<Batch>): Batch {
    const items = patch.items ?? stored.batch.items;
    const next: Batch = {
      ...stored.batch,
      ...patch,
      itemCount: items.length,
      version: stored.batch.version + 1,
    };
    stored.batch = next;
    return next;
  }

  private staffDecide(
    batchId: string,
    decision: 'approved' | 'rejected',
    reason: string | null,
  ): Batch {
    const stored = this.mustGet(batchId);
    const quote = stored.batch.currentQuote;
    if (stored.batch.status !== 'quote_pending' || quote?.decision !== 'pending') {
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

  private batchCommand(
    batchId: string,
    pre: Preconditions,
    fields: Record<string, string | number>,
    status: 200 | 201,
    run: (stored: StoredBatch) => Batch,
  ): CommandResult<Batch> {
    const stored = this.visible(batchId);
    return this.idempotent(`batch:${batchId}`, pre, fields, status, () => {
      if (pre.ifMatch !== etagOf(stored.batch)) throw reject('VERSION_MISMATCH');
      const next = run(stored);
      return { value: next, etag: etagOf(next) };
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

  /** Bill a printed batch (or a historical order) once, in its São Paulo month. */
  private charge(printedAt: string, item: CloseItem): void {
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
    close.items.push(item);
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
      etag: `"${close.id}:${close.version}"`,
    };
  }
}

function etagOf(batch: Batch): string {
  return `"${batch.id}:${batch.version}"`;
}

function summary(batch: Batch) {
  return {
    id: batch.id,
    reference: batch.reference,
    status: batch.status,
    version: batch.version,
    itemCount: batch.itemCount,
    createdAt: batch.createdAt,
    collectedAt: batch.collectedAt,
    printedAt: batch.printedAt,
    receivedAt: batch.receivedAt,
    approvedAmountCents: batch.approvedAmountCents,
  };
}

function encodeCursor(batch: Batch, status: BatchStatus | undefined): string {
  return Buffer.from(JSON.stringify([batch.createdAt, batch.id, status ?? null])).toString(
    'base64url',
  );
}

function decodeCursor(
  cursor: string,
  status: BatchStatus | undefined,
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
  const mime = sniffDocumentMime(bytes);
  if (!mime) throw reject('UNSUPPORTED_MEDIA_TYPE');
  return mime;
}
