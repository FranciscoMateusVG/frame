import { type Span, SpanStatusCode, trace } from '@opentelemetry/api';
import type { z } from 'zod';
import type { MonthlyClose } from '../domain/monthly-close.js';
import type { Batch, BatchPage } from '../domain/print-batch.js';
import { UpstreamRejectedError } from '../errors/upstream-rejected.error.js';
import { UpstreamUnavailableError } from '../errors/upstream-unavailable.error.js';
import { markSpanFailed } from '../observability/span-errors.js';
import {
  BatchListResponseSchema,
  BatchResponseSchema,
  CloseResponseSchema,
  ErrorSchema,
  OpenBatchResponseSchema,
} from './print-api.contract.js';
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

export interface PrintApiHttpOptions {
  /** Fixed origin of the Incluir API, e.g. `https://api.example.org`. Never user input. */
  readonly origin: string;
  /** Service bearer token. Server-only; never logged, never put on a span. */
  readonly token: string;
  /** Deadline for JSON calls and command uploads (ms). */
  readonly timeoutMs?: number;
  /** Deadline for a whole file download, body included (ms). */
  readonly downloadTimeoutMs?: number;
  /** Largest download accepted from upstream (bytes). */
  readonly maxDownloadBytes?: number;
  /** Injectable for tests; defaults to the global fetch. */
  readonly fetch?: typeof fetch;
}

/** Print files may be up to 20 MiB (Incluir staging limit); documents 5 MiB. */
const DEFAULT_MAX_DOWNLOAD = 25 * 1024 * 1024;

/**
 * PrintApi over HTTP — the only component that knows the service token and
 * the upstream origin.
 *
 * Hardening (spec §4.5, §5): fixed origin + fixed path templates (ids are
 * path-encoded), `redirect: 'manual'` with any 3xx treated as unavailable so
 * the bearer never follows a redirect, hard timeouts, strict response
 * parsing against the frozen schema, size-capped streaming downloads, and no
 * retries (a write is never re-sent with a new key).
 */
export class PrintApiHttp implements PrintApi {
  private readonly base: string;
  private readonly host: string;
  private readonly timeoutMs: number;
  private readonly downloadTimeoutMs: number;
  private readonly maxDownloadBytes: number;
  private readonly fetchImpl: typeof fetch;

  constructor(private readonly options: PrintApiHttpOptions) {
    const origin = new URL(options.origin);
    this.base = `${origin.origin}${PRINT_API_PREFIX}`;
    this.host = origin.host;
    this.timeoutMs = options.timeoutMs ?? 10_000;
    this.downloadTimeoutMs = options.downloadTimeoutMs ?? 120_000;
    this.maxDownloadBytes = options.maxDownloadBytes ?? DEFAULT_MAX_DOWNLOAD;
    this.fetchImpl = options.fetch ?? fetch;
  }

  listBatches(query: ListBatchesQuery): Promise<BatchPage> {
    const params = new URLSearchParams({ limit: String(query.limit) });
    if (query.status) params.set('status', query.status);
    if (query.cursor) params.set('cursor', query.cursor);
    return this.span('listBatches', 'GET', '/batches', async (span) => {
      const res = await this.send('GET', `/batches?${params}`, span, {});
      return (await this.json(res, BatchListResponseSchema)) as BatchPage;
    });
  }

  getOpenBatch(): Promise<Tagged<Batch> | null> {
    return this.span('getOpenBatch', 'GET', '/batches/open', async (span) => {
      const res = await this.send('GET', '/batches/open', span, {});
      const body = await this.json(res, OpenBatchResponseSchema);
      // ETag only when nonnull.
      return body.batch === null ? null : { value: body.batch as Batch, etag: this.etag(res) };
    });
  }

  getBatch(batchId: string): Promise<Tagged<Batch>> {
    return this.span('getBatch', 'GET', '/batches/:id', async (span) => {
      const res = await this.send('GET', `/batches/${seg(batchId)}`, span, {});
      const body = await this.json(res, BatchResponseSchema);
      return { value: body.batch as Batch, etag: this.etag(res) };
    });
  }

  downloadBatchFile(batchId: string, orderId: string, fileId: string): Promise<Download> {
    return this.span(
      'downloadBatchFile',
      'GET',
      '/batches/:id/orders/:orderId/files/:fileId',
      (span) =>
        this.download(`/batches/${seg(batchId)}/orders/${seg(orderId)}/files/${seg(fileId)}`, span),
    );
  }

  downloadQuoteFile(batchId: string, quoteId: string): Promise<Download> {
    return this.span('downloadQuoteFile', 'GET', '/batches/:id/quotes/:quoteId/file', (span) =>
      this.download(`/batches/${seg(batchId)}/quotes/${seg(quoteId)}/file`, span),
    );
  }

  markCollected(batchId: string, pre: Preconditions): Promise<CommandResult<Batch>> {
    return this.span('markCollected', 'POST', '/batches/:id/collected', async (span) => {
      const res = await this.send('POST', `/batches/${seg(batchId)}/collected`, span, {
        pre,
        json: {},
      });
      return this.command(res, BatchResponseSchema, (b) => b.batch as Batch);
    });
  }

  submitQuote(
    batchId: string,
    input: { readonly amountCents: number; readonly file: Upload },
    pre: Preconditions,
  ): Promise<CommandResult<Batch>> {
    return this.span('submitQuote', 'POST', '/batches/:id/quotes', async (span) => {
      const form = new FormData();
      form.set('file', new Blob([toArrayBuffer(input.file.bytes)]), input.file.filename);
      form.set('amountCents', String(input.amountCents));
      const res = await this.send('POST', `/batches/${seg(batchId)}/quotes`, span, {
        pre,
        form,
      });
      return this.command(res, BatchResponseSchema, (b) => b.batch as Batch);
    });
  }

  markPrinted(
    batchId: string,
    input: { readonly quoteId: string },
    pre: Preconditions,
  ): Promise<CommandResult<Batch>> {
    return this.span('markPrinted', 'POST', '/batches/:id/printed', async (span) => {
      const res = await this.send('POST', `/batches/${seg(batchId)}/printed`, span, {
        pre,
        json: { quoteId: input.quoteId },
      });
      return this.command(res, BatchResponseSchema, (b) => b.batch as Batch);
    });
  }

  getMonthlyClose(competence: string): Promise<Tagged<MonthlyClose>> {
    return this.span('getMonthlyClose', 'GET', '/monthly-closes/:competence', async (span) => {
      const res = await this.send('GET', `/monthly-closes/${seg(competence)}`, span, {});
      const body = await this.json(res, CloseResponseSchema);
      return { value: body.close as MonthlyClose, etag: this.etag(res) };
    });
  }

  submitInvoice(
    competence: string,
    input: { readonly declaredTotalCents: number; readonly file: Upload },
    pre: Preconditions,
  ): Promise<CommandResult<MonthlyClose>> {
    return this.span(
      'submitInvoice',
      'POST',
      '/monthly-closes/:competence/invoice',
      async (span) => {
        const form = new FormData();
        form.set('file', new Blob([toArrayBuffer(input.file.bytes)]), input.file.filename);
        form.set('declaredTotalCents', String(input.declaredTotalCents));
        const res = await this.send('POST', `/monthly-closes/${seg(competence)}/invoice`, span, {
          pre,
          form,
        });
        return this.command(res, CloseResponseSchema, (b) => b.close as MonthlyClose);
      },
    );
  }

  downloadInvoice(competence: string): Promise<Download> {
    return this.span('downloadInvoice', 'GET', '/monthly-closes/:competence/invoice', (span) =>
      this.download(`/monthly-closes/${seg(competence)}/invoice`, span),
    );
  }

  // ── plumbing ──

  private span<T>(
    operation: string,
    method: string,
    template: string,
    fn: (span: Span) => Promise<T>,
  ): Promise<T> {
    return tracer.startActiveSpan(`print_api.${operation}`, async (span) => {
      span.setAttribute('http.request.method', method);
      span.setAttribute('url.template', `${PRINT_API_PREFIX}${template}`);
      span.setAttribute('server.address', this.host);
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

  private async send(
    method: 'GET' | 'POST',
    path: string,
    span: Span,
    opts: { pre?: Preconditions; json?: unknown; form?: FormData; download?: boolean },
  ): Promise<Response> {
    const headers = new Headers({ Authorization: `Bearer ${this.options.token}` });
    headers.set('Accept', opts.download ? '*/*' : 'application/json');
    if (opts.pre?.ifMatch !== undefined) headers.set('If-Match', opts.pre.ifMatch);
    if (opts.pre?.idempotencyKey !== undefined)
      headers.set('Idempotency-Key', opts.pre.idempotencyKey);
    let body: string | FormData | undefined;
    if (opts.json !== undefined) {
      headers.set('Content-Type', 'application/json');
      body = JSON.stringify(opts.json);
    } else if (opts.form) {
      body = opts.form;
    }

    let res: Response;
    try {
      res = await this.fetchImpl(`${this.base}${path}`, {
        method,
        headers,
        redirect: 'manual',
        signal: AbortSignal.timeout(opts.download ? this.downloadTimeoutMs : this.timeoutMs),
        ...(body !== undefined ? { body } : {}),
      });
    } catch (error) {
      const name = (error as Error).name;
      throw new UpstreamUnavailableError(
        name === 'TimeoutError' || name === 'AbortError' ? 'timeout' : 'network error',
      );
    }
    span.setAttribute('http.response.status_code', res.status);
    if (res.ok) return res;
    return this.fail(res);
  }

  /** Map a non-2xx answer to a typed error. Always throws. */
  private async fail(res: Response): Promise<never> {
    if (res.type === 'opaqueredirect' || (res.status >= 300 && res.status < 400)) {
      await discard(res);
      throw new UpstreamUnavailableError('redirect refused');
    }
    // 401: our service credential was refused; 5xx/503 NOT_CONFIGURED: upstream
    // misconfigured or down. Neither is something the print shop can fix by
    // logging in again (spec §4.5).
    if (res.status === 401 || res.status >= 500) {
      await discard(res);
      throw new UpstreamUnavailableError(`upstream status ${res.status}`);
    }
    const parsed = ErrorSchema.safeParse(await readJson(res));
    if (!parsed.success) throw new UpstreamUnavailableError('malformed error body');
    const { code, message, requestId } = parsed.data.error;
    throw new UpstreamRejectedError(
      res.status,
      code,
      message,
      requestId,
      parseRetryAfter(res.headers.get('retry-after')),
    );
  }

  private async json<S extends z.ZodType>(res: Response, schema: S): Promise<z.infer<S>> {
    const parsed = schema.safeParse(await readJson(res));
    if (!parsed.success) throw new UpstreamUnavailableError('response violates contract');
    return parsed.data;
  }

  private etag(res: Response): string {
    const etag = res.headers.get('etag');
    if (!etag || !/^"[^"\r\n]{1,200}"$/.test(etag)) {
      throw new UpstreamUnavailableError('missing ETag');
    }
    return etag;
  }

  private async command<S extends z.ZodType, T>(
    res: Response,
    schema: S,
    pick: (body: z.infer<S>) => T,
  ): Promise<CommandResult<T>> {
    const body = await this.json(res, schema);
    const status = res.status === 201 ? 201 : 200;
    return {
      value: pick(body),
      etag: this.etag(res),
      status,
      replayed: res.headers.get('idempotency-replayed') === 'true',
    };
  }

  private async download(path: string, span: Span): Promise<Download> {
    const res = await this.send('GET', path, span, { download: true });
    const size = Number(res.headers.get('content-length'));
    if (!res.body || !Number.isSafeInteger(size) || size < 0 || size > this.maxDownloadBytes) {
      await discard(res);
      throw new UpstreamUnavailableError('download without valid length');
    }
    span.setAttribute('http.response.body.size', size);
    return {
      filename: filenameFrom(res.headers.get('content-disposition')),
      mime: mimeFrom(res.headers.get('content-type')),
      size,
      body: res.body.pipeThrough(exactLength(size)),
    };
  }
}

/** Encode one path segment; ids never introduce `/`, `..` or a query. */
function seg(value: string): string {
  return encodeURIComponent(value);
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

/** Largest JSON answer accepted from upstream (a full batch is far below this). */
const MAX_JSON_BYTES = 2 * 1024 * 1024;

/** Read and parse a JSON body, refusing more than MAX_JSON_BYTES without buffering it. */
async function readJson(res: Response): Promise<unknown> {
  const declared = Number(res.headers.get('content-length') ?? '0');
  if (declared > MAX_JSON_BYTES || !res.body) {
    await discard(res);
    if (declared > MAX_JSON_BYTES) throw new UpstreamUnavailableError('response too large');
    return undefined;
  }
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_JSON_BYTES) {
      await reader.cancel().catch(() => undefined);
      throw new UpstreamUnavailableError('response too large');
    }
    chunks.push(value);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    return undefined;
  }
}

async function discard(res: Response): Promise<void> {
  try {
    await res.body?.cancel();
  } catch {
    // nothing to release
  }
}

function parseRetryAfter(value: string | null): number | null {
  if (value === null || !/^\d{1,6}$/.test(value)) return null;
  return Number(value);
}

/** Stream that fails if upstream sends more or fewer bytes than announced. */
function exactLength(expected: number): TransformStream<Uint8Array, Uint8Array> {
  let seen = 0;
  return new TransformStream({
    transform(chunk, controller) {
      seen += chunk.byteLength;
      if (seen > expected) {
        controller.error(new UpstreamUnavailableError('download exceeded announced length'));
        return;
      }
      controller.enqueue(chunk);
    },
    flush(controller) {
      if (seen !== expected) {
        controller.error(new UpstreamUnavailableError('download shorter than announced length'));
      }
    },
  });
}

/** Content-Disposition → original filename (RFC 6266 `filename*` preferred). */
export function filenameFrom(header: string | null): string {
  if (header) {
    const star = /filename\*\s*=\s*UTF-8''([^;]+)/i.exec(header);
    if (star?.[1]) {
      try {
        return decodeURIComponent(star[1].trim());
      } catch {
        // fall through to the plain parameter
      }
    }
    const plain = /filename\s*=\s*"([^"]*)"/i.exec(header);
    if (plain?.[1]) return plain[1];
  }
  return 'arquivo';
}

function mimeFrom(header: string | null): string {
  const value = header?.split(';')[0]?.trim().toLowerCase() ?? '';
  return /^[a-z0-9][a-z0-9!#$&^_.+-]{0,63}\/[a-z0-9][a-z0-9!#$&^_.+-]{0,63}$/.test(value)
    ? value
    : 'application/octet-stream';
}
