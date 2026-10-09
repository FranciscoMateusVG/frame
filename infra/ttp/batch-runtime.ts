import {
  BatchError,
  BatchState,
  type FileDto,
  type Preconditions,
  type Reply,
} from './batch-state.js';
import { type ContractFreeze, sha256 } from './contract-freeze.js';
import { pairingCases, pairingSeedItem } from './pairing-seed.js';
import { ControlError, type SeedFactory } from './trial-control.js';

export type Upload = { bytes: Buffer; mime: string; name: string };
type CloseItem = {
  kind: 'batch' | 'legacy_order';
  batchId?: string;
  orderId?: string;
  reference: string;
  quoteId: string;
  amountCents: number;
  printedAt: string;
};
type Close = {
  id: string | null;
  competence: string;
  version: number;
  state: 'open' | 'submitted' | 'rejected' | 'accepted';
  periodClosed: boolean;
  items: CloseItem[];
  expectedTotalCents: number;
  declaredTotalCents: number | null;
  document: FileDto | null;
  rejectionReason: string | null;
  submittedAt: string | null;
  acceptedAt: string | null;
};
const moment = '2026-09-10T12:00:00.000Z';
const clockMonth = '2026-10'; // Fixed acceptance clock, not host wall clock.
function fail(status: number, code: string): never {
  throw new BatchError(status, code);
}
export class RateError extends BatchError {
  constructor(readonly retryAfter: number) {
    super(429, 'RATE_LIMITED');
  }
}

export class BatchRuntime extends BatchState {
  private sequence = 0;
  private uploads = new Map<string, Buffer>();
  private uploadBytes = 0;
  private invoices = new Map<string, Close>();
  private quoteFault = false;
  private counters = new Map<string, { until: number; count: number }>();
  readonly checkpoints: string[] = [];
  constructor(
    readonly freeze: ContractFreeze,
    readonly scenario: string,
    readonly generation = 1,
  ) {
    const f = freeze.fixture;
    const initial =
      scenario === 'cancel'
        ? f.batches.find((b) => b.status === 'quote_approved')
        : scenario === 'empty-history'
          ? f.batches.find((b) => b.status === 'received')
          : f.batches[0];
    if (!initial) throw new Error('INVALID_SEED');
    const batches = [structuredClone(initial)];
    if (scenario.startsWith('pairing-'))
      batches[0].items = [pairingSeedItem(freeze, scenario.slice(8))];
    super({
      batches,
      nextBatch: (items) =>
        structuredClone(
          items.some((i) => i.previouslyCancelledIn) ? f.rebatchedBatch.batch : f.nextBatch.batch,
        ),
      now: moment,
    });
    if (scenario === 'cancel') this.publish(f.queuedItem);
  }
  rate(kind: 'read' | 'command' | 'upload', now = Date.now()) {
    const max = kind === 'read' ? 120 : kind === 'command' ? 30 : 10;
    const duration = kind === 'upload' ? 3_600_000 : 60_000;
    let c = this.counters.get(kind);
    if (!c || now >= c.until) {
      c = { until: now + duration, count: 0 };
      this.counters.set(kind, c);
    }
    if (c.count >= max) throw new RateError(Math.max(1, Math.ceil((c.until - now) / 1000)));
    c.count++;
  }
  private download(file: FileDto | undefined) {
    if (!file) return fail(404, 'NOT_FOUND');
    const bytes = this.uploads.get(file.id) ?? this.freeze.assets.get(file.id);
    if (!bytes) return fail(404, 'NOT_FOUND');
    return { file: structuredClone(file), bytes };
  }
  memberFile(id: string, orderId: string, fileId: string) {
    const item = this.get(id).items.find((i) => i.orderId === orderId);
    if (!item) return fail(404, 'NOT_FOUND');
    const files = [...item.jobs.map((j) => j.file), ...(item.generalInstructions?.files ?? [])];
    return this.download(files.find((f) => f.id === fileId));
  }
  quoteFile(id: string, quoteId: string) {
    const q = this.get(id).currentQuote;
    if (!q || q.id !== quoteId) return fail(404, 'NOT_FOUND');
    return this.download(q.document);
  }
  private nextId(offset = 1) {
    const h = sha256(JSON.stringify([this.scenario, this.generation, this.sequence + offset]));
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
  }
  private document(u: Upload, offset = 1): FileDto {
    return {
      id: this.nextId(offset),
      name: u.name,
      mime: u.mime,
      bytes: u.bytes.length,
      sha256: sha256(u.bytes),
    };
  }
  private capacity(u: Upload) {
    if (this.uploads.size >= 64 || this.uploadBytes + u.bytes.length > 32 * 1024 * 1024)
      fail(503, 'UPSTREAM_UNAVAILABLE');
  }
  private store(file: FileDto, u: Upload) {
    this.uploads.set(file.id, Buffer.from(u.bytes));
    this.uploadBytes += u.bytes.length;
  }
  uploadQuote(id: string, u: Upload, amountCents: number, pre: Preconditions) {
    const b = this.get(id);
    // Capacity is conservative, bounded per trial; successful replay allocates no bytes.
    const r = this.submitQuote(
      id,
      {
        id: this.nextId(),
        revision: (b.currentQuote?.revision ?? 0) + 1,
        amountCents,
        currency: 'BRL',
        document: this.document(u, 2),
        decision: 'pending',
        rejectionReason: null,
        submittedAt: moment,
        decidedAt: null,
      },
      pre,
      () => this.capacity(u),
      (batch) => this.freeze.validate('BatchResponse', { batch }),
    );
    const quote = r.body.batch.currentQuote;
    if (!quote) return fail(500, 'INTERNAL');
    if (!r.replayed) {
      this.store(quote.document, u);
      this.sequence += 2;
    }
    return r;
  }
  consumeQuoteFault(replayed: boolean) {
    if (!replayed && this.quoteFault) {
      this.quoteFault = false;
      return true;
    }
    return false;
  }
  month(competence: string): { close: Close } {
    if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(competence)) return fail(400, 'INVALID_COMPETENCE');
    const saved = this.invoices.get(competence);
    if (saved) return { close: structuredClone(saved) };
    const historical = this.freeze.fixture.monthlyClose.close;
    const items: CloseItem[] =
      competence === historical.competence
        ? (structuredClone(
            historical.items.filter((i) => i.kind === 'legacy_order'),
          ) as CloseItem[])
        : [];
    for (const b of this.list()) {
      if (
        !['printed', 'received'].includes(b.status) ||
        !b.printedAt ||
        !b.currentQuote ||
        b.printedAt.slice(0, 7) !== competence
      )
        continue;
      items.unshift({
        kind: 'batch',
        batchId: b.id,
        reference: b.reference,
        quoteId: b.currentQuote.id,
        amountCents: b.currentQuote.amountCents,
        printedAt: b.printedAt,
      });
    }
    const close: Close = {
      id: items.length ? historical.id : null,
      competence,
      version: items.length,
      state: 'open',
      periodClosed: competence < clockMonth,
      items,
      expectedTotalCents: items.reduce((s, i) => s + i.amountCents, 0),
      declaredTotalCents: null,
      document: null,
      rejectionReason: null,
      submittedAt: null,
      acceptedAt: null,
    };
    this.freeze.validate('BatchCloseResponse', { close });
    return { close };
  }
  monthEtag(competence: string) {
    const c = this.month(competence).close;
    return c.id ? `"${c.id}:${c.version}"` : `"month:${competence}:0"`;
  }
  uploadInvoice(
    competence: string,
    u: Upload,
    amount: number,
    pre: Preconditions,
  ): Reply<{ close: Close }> {
    const c = this.month(competence).close;
    return this.replay(
      `monthly-closes/${competence}/invoice`,
      [amount, sha256(u.bytes), u.name, u.mime],
      pre,
      this.monthEtag(competence),
      () => {
        if (!c.periodClosed) fail(409, 'PERIOD_OPEN');
        if (!c.items.length) fail(409, 'EMPTY_CLOSE');
        if (!['open', 'rejected'].includes(c.state)) fail(409, 'INVALID_STATE');
        if (amount !== c.expectedTotalCents) fail(409, 'TOTAL_MISMATCH');
        this.capacity(u);
        c.state = 'submitted';
        c.version++;
        c.document = this.document(u);
        c.declaredTotalCents = amount;
        c.submittedAt = moment;
        c.rejectionReason = null;
        this.freeze.validate('BatchCloseResponse', { close: c });
        this.store(c.document, u);
        this.sequence += 1;
        this.invoices.set(competence, structuredClone(c));
        return {
          status: 201,
          body: { close: structuredClone(c) },
          etag: this.monthEtag(competence),
          replayed: false,
        };
      },
    );
  }
  invoiceFile(competence: string) {
    return this.download(this.month(competence).close.document ?? undefined);
  }
  // Fixed synthetic events only: no arbitrary IDs, DTOs, SQL, code or data injection.
  checkpoint(event: string) {
    const id = this.freeze.fixture.batches[0].id;
    const b = this.get(id);
    if (this.checkpoints.length >= 64) throw new ControlError(409, 'CHECKPOINT_LIMIT');
    switch (event) {
      case 'revise-open':
        this.reviseOpen(id);
        break;
      case 'publish-queued':
        this.publish(this.freeze.fixture.queuedItem);
        break;
      case 'reject-quote':
      case 'approve-quote':
        if (!b.currentQuote) throw new ControlError(409, 'CHECKPOINT_INVALID_STATE');
        this.decide(
          id,
          b.currentQuote.id,
          event === 'reject-quote' ? 'rejected' : 'approved',
          'Ajustar orçamento sintético.',
        );
        break;
      case 'receive':
        this.receive(id);
        break;
      case 'cancel':
        this.cancel(id, 'Cancelamento sintético confirmado.');
        break;
      case 'quote-commit-503':
        if (this.quoteFault) throw new ControlError(409, 'CHECKPOINT_INVALID_STATE');
        this.quoteFault = true;
        break;
      default:
        throw new ControlError(400, 'UNKNOWN_CHECKPOINT');
    }
    this.checkpoints.push(event);
    return { checkpoint: event, sequence: this.checkpoints.length };
  }
}
export function seedFactory(freeze: ContractFreeze): SeedFactory<BatchRuntime> {
  return (scenario, context = { generation: 1 }) => {
    if (
      ![
        'flow',
        'cancel',
        'empty-history',
        ...pairingCases(freeze).map((c) => `pairing-${c.name}`),
      ].includes(scenario)
    )
      throw new ControlError(400, 'UNKNOWN_SCENARIO');
    return {
      state: new BatchRuntime(freeze, scenario, context.generation),
      seed_sha256: sha256(
        JSON.stringify({
          bundle: freeze.bundleHash,
          scenario,
          clock: clockMonth,
          generation: context.generation,
          policy: 'ttp-v2-2',
        }),
      ),
    };
  };
}
