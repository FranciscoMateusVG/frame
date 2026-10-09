// Stateful synthetic model, not a Hono implementation or a production adapter.
import { createHash } from 'node:crypto';

export type BatchStatus =
  | 'open'
  | 'files_collected'
  | 'quote_pending'
  | 'quote_rejected'
  | 'quote_approved'
  | 'printed'
  | 'received'
  | 'cancelled';
export type FileDto = { id: string; name: string; mime: string; bytes: number; sha256: string };
export type BatchItem = {
  orderId: string;
  reference: string;
  title: string;
  revision: number;
  jobs: { id: string; title: string; copies: number; instructions: string; file: FileDto }[];
  generalInstructions?: { text: string; files: FileDto[] };
  previouslyCancelledIn?: string;
};
export type Quote = {
  id: string;
  revision: number;
  amountCents: number;
  currency: 'BRL';
  document: FileDto;
  decision: 'pending' | 'approved' | 'rejected';
  rejectionReason: string | null;
  submittedAt: string;
  decidedAt: string | null;
};
export type Batch = {
  id: string;
  reference: string;
  status: BatchStatus;
  version: number;
  itemCount: number;
  createdAt: string;
  collectedAt: string | null;
  printedAt: string | null;
  receivedAt: string | null;
  approvedAmountCents: number | null;
  items: BatchItem[];
  currentQuote: Quote | null;
  cancellationReason: string | null;
};
export type Preconditions = { key: string; etag: string };
export type Reply<B> = {
  status: number;
  body: B;
  etag: string;
  replayed: boolean;
};
export type BatchReply = Reply<{ batch: Batch }>;
type MemberStatus = 'pending' | 'in_progress' | 'approved';
const terminal = (b: Batch) => b.status === 'received' || b.status === 'cancelled';
export class BatchError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
  }
}
function reject(status: number, code: string): never {
  throw new BatchError(status, code);
}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export class BatchState {
  private batches: Map<string, Batch>;
  private pending: BatchItem[] = [];
  private members = new Map<string, MemberStatus>();
  private ledger = new Map<string, { fingerprint: string; reply: Reply<unknown> }>();
  private readonly now: string;
  constructor(
    private readonly seed: {
      batches: Batch[];
      nextBatch: (items: BatchItem[]) => Batch;
      now?: string;
    },
  ) {
    if (seed.batches.filter((b) => !terminal(b)).length > 1) reject(500, 'INVALID_SEED');
    this.batches = new Map(seed.batches.map((b) => [b.id, structuredClone(b)]));
    this.now = seed.now ?? '2026-09-10T12:00:00.000Z';
    for (const b of seed.batches)
      for (const i of b.items)
        this.members.set(
          i.orderId,
          b.status === 'received'
            ? 'approved'
            : b.status === 'open' || b.status === 'cancelled'
              ? 'pending'
              : 'in_progress',
        );
  }
  private lookup(id: string): Batch {
    const b = this.batches.get(id);
    if (!b) reject(404, 'NOT_FOUND');
    return b;
  }
  private current() {
    return [...this.batches.values()].find((b) => !terminal(b));
  }
  get(id: string): Batch {
    return structuredClone(this.lookup(id));
  }
  list(): Batch[] {
    return structuredClone(
      [...this.batches.values()].sort(
        (a, b) => a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id),
      ),
    );
  }
  open(): Batch | null {
    const b = this.current();
    return b?.status === 'open' ? structuredClone(b) : null;
  }
  etag(id: string) {
    const b = this.lookup(id);
    return `"${b.id}:${b.version}"`;
  }
  // Administrative evidence only. Never include this or pending in supplier DTOs.
  memberStatus(id: string) {
    return this.members.get(id);
  }

  private transaction<T>(operation: () => T): T {
    const snapshot = structuredClone({
      batches: this.batches,
      pending: this.pending,
      members: this.members,
    });
    try {
      return operation();
    } catch (error) {
      this.batches = snapshot.batches;
      this.pending = snapshot.pending;
      this.members = snapshot.members;
      throw error;
    }
  }
  protected replay<T>(
    scope: string,
    fields: unknown,
    pre: Preconditions,
    expected: string,
    operation: () => Reply<T>,
  ): Reply<T> {
    if (!pre.key || !pre.etag) reject(428, 'PRECONDITION_REQUIRED');
    if (!uuid.test(pre.key)) reject(400, 'INVALID_REQUEST');
    const fingerprint = createHash('sha256')
      .update(JSON.stringify([scope, pre.etag, fields]))
      .digest('hex');
    const seen = this.ledger.get(pre.key);
    if (seen) {
      if (seen.fingerprint !== fingerprint) reject(409, 'IDEMPOTENCY_CONFLICT');
      return { ...(structuredClone(seen.reply) as Reply<T>), replayed: true };
    }
    if (pre.etag !== expected) reject(412, 'VERSION_MISMATCH');
    if (this.ledger.size >= 1024) reject(503, 'UPSTREAM_UNAVAILABLE');
    const reply = operation();
    this.ledger.set(pre.key, { fingerprint, reply: structuredClone(reply) });
    return reply;
  }
  private command(
    id: string,
    action: string,
    fields: unknown,
    pre: Preconditions,
    status: number,
    operation: (b: Batch) => void,
  ): BatchReply {
    this.lookup(id); // Ownership/existence before idempotency lookup; HTTP authenticates first.
    return this.replay(`${id}/${action}`, fields, pre, this.etag(id), () =>
      this.transaction(() => {
        const b = this.lookup(id);
        operation(b);
        b.version += 1;
        return {
          status,
          body: { batch: structuredClone(b) },
          etag: this.etag(id),
          replayed: false,
        };
      }),
    );
  }
  collect(id: string, pre: Preconditions) {
    return this.command(id, 'collected', {}, pre, 200, (b) => {
      if (b.status !== 'open' || this.current()?.id !== id) reject(409, 'INVALID_STATE');
      if (!b.items.length) reject(409, 'EMPTY_BATCH');
      if (b.items.some((i) => this.members.get(i.orderId) !== 'pending'))
        reject(409, 'INVALID_STATE');
      for (const i of b.items) this.members.set(i.orderId, 'in_progress');
      b.status = 'files_collected';
      b.collectedAt = this.now;
    });
  }
  submitQuote(id: string, quote: Quote, pre: Preconditions, beforeCommit = () => {}) {
    const intention = [
      quote.amountCents,
      quote.document.sha256,
      quote.document.name,
      quote.document.mime,
    ];
    return this.command(id, 'quotes', intention, pre, 201, (b) => {
      if (!['files_collected', 'quote_rejected'].includes(b.status)) reject(409, 'INVALID_STATE');
      if (
        !Number.isInteger(quote.amountCents) ||
        quote.amountCents < 1 ||
        quote.amountCents > 2147483647
      )
        reject(400, 'INVALID_REQUEST');
      beforeCommit();
      b.currentQuote = {
        ...structuredClone(quote),
        decision: 'pending',
        rejectionReason: null,
        decidedAt: null,
      };
      b.status = 'quote_pending';
      b.approvedAmountCents = null;
    });
  }
  print(id: string, quoteId: string, pre: Preconditions) {
    return this.command(id, 'printed', { quoteId }, pre, 200, (b) => {
      if (
        b.status !== 'quote_approved' ||
        b.currentQuote?.id !== quoteId ||
        b.currentQuote.decision !== 'approved'
      )
        reject(409, 'INVALID_STATE');
      b.status = 'printed';
      b.printedAt = this.now;
    });
  }
  // The following are admin-only fixture controls, NOT service-token routes.
  decide(id: string, quoteId: string, decision: 'approved' | 'rejected', reason?: string) {
    this.transaction(() => {
      const b = this.lookup(id);
      if (b.status !== 'quote_pending' || b.currentQuote?.id !== quoteId)
        reject(409, 'INVALID_STATE');
      if (decision === 'rejected' && (!reason?.trim() || reason.trim().length > 500))
        reject(400, 'INVALID_REQUEST');
      b.currentQuote.decision = decision;
      b.currentQuote.decidedAt = this.now;
      b.currentQuote.rejectionReason = decision === 'rejected' ? (reason?.trim() ?? null) : null;
      b.approvedAmountCents = decision === 'approved' ? b.currentQuote.amountCents : null;
      b.status = decision === 'approved' ? 'quote_approved' : 'quote_rejected';
      b.version += 1;
    });
  }
  reviseOpen(id: string) {
    this.transaction(() => {
      const b = this.lookup(id);
      const item = b.items[0];
      if (b.status !== 'open' || !item) reject(409, 'INVALID_STATE');
      item.revision++;
      b.version++;
    });
  }
  publish(item: BatchItem) {
    this.transaction(() => {
      const current = this.current();
      if (
        this.pending.some((i) => i.orderId === item.orderId) ||
        current?.items.some((i) => i.orderId === item.orderId)
      )
        reject(409, 'INVALID_STATE');
      this.members.set(item.orderId, 'pending');
      if (current?.status === 'open') {
        current.items.push(structuredClone(item));
        current.itemCount += 1;
        current.version += 1;
      } else {
        this.pending.push(structuredClone(item));
        if (!current) this.exposePending();
      }
    });
  }
  private exposePending() {
    if (!this.pending.length) return;
    if (this.current()) reject(409, 'INVALID_STATE');
    const b = this.seed.nextBatch(structuredClone(this.pending));
    if (
      this.batches.has(b.id) ||
      b.status !== 'open' ||
      b.currentQuote !== null ||
      b.approvedAmountCents !== null ||
      b.itemCount !== this.pending.length ||
      JSON.stringify(b.items) !== JSON.stringify(this.pending)
    )
      reject(500, 'INVALID_SEED');
    this.batches.set(b.id, structuredClone(b));
    this.pending = [];
  }
  receive(id: string) {
    this.transaction(() => {
      const b = this.lookup(id);
      if (b.status !== 'printed') reject(409, 'INVALID_STATE');
      for (const item of b.items) this.members.set(item.orderId, 'approved');
      b.status = 'received';
      b.receivedAt = this.now;
      b.version += 1;
      this.exposePending();
    });
  }
  cancel(id: string, reason: string) {
    this.transaction(() => {
      const b = this.lookup(id);
      if (terminal(b) || b.status === 'printed') reject(409, 'INVALID_STATE');
      if (!reason.trim() || reason.trim().length > 500) reject(400, 'INVALID_REQUEST');
      for (const item of b.items) this.members.set(item.orderId, 'pending');
      this.pending = [
        ...b.items.map((item) => ({
          ...structuredClone(item),
          previouslyCancelledIn: b.reference,
        })),
        ...this.pending,
      ];
      b.status = 'cancelled';
      b.cancellationReason = reason.trim();
      b.version += 1;
      this.exposePending();
    });
  }
}
