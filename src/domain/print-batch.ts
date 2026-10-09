/**
 * Print-shop portal — batch domain (frozen contract print-portal-v2.schema.json,
 * monorepo-incluir #1053).
 *
 * A batch (lote) is the whole set of requests going to the print shop
 * together, with one progress and one quote. These are the shapes the portal
 * receives from the Incluir service API and re-serves to the browser. The
 * portal is not the authority for any of this state; the pure helpers below
 * only decide what the UI may OFFER. The upstream re-checks every rule.
 */

export const BATCH_STATUSES = [
  'open',
  'files_collected',
  'quote_pending',
  'quote_rejected',
  'quote_approved',
  'printed',
  'received',
  'cancelled',
] as const;

export type BatchStatus = (typeof BATCH_STATUSES)[number];

/** Statuses of the one batch the print shop is working on after collection. */
export const ACTIVE_BATCH_STATUSES = [
  'files_collected',
  'quote_pending',
  'quote_rejected',
  'quote_approved',
  'printed',
] as const satisfies readonly BatchStatus[];

export const QUOTE_DECISIONS = ['pending', 'approved', 'rejected'] as const;
export type QuoteDecision = (typeof QUOTE_DECISIONS)[number];

/** A stored file. Never carries bucket/key/url. */
export interface PrintFile {
  readonly id: string;
  readonly name: string;
  readonly mime: string;
  readonly bytes: number;
  readonly sha256: string;
}

export interface PrintJob {
  readonly id: string;
  readonly title: string;
  readonly copies: number;
  readonly instructions: string;
  readonly file: PrintFile;
}

/** One request (solicitação) inside a batch. */
export interface BatchItem {
  readonly orderId: string;
  readonly reference: string;
  readonly title: string;
  readonly revision: number;
  readonly jobs: readonly PrintJob[];
  /** Residual legacy text/files with no safe per-file association. */
  readonly generalInstructions?: { readonly text: string; readonly files: readonly PrintFile[] };
  /** Reference of the latest cancelled batch this request was in (`LOT-0007`). */
  readonly previouslyCancelledIn?: string;
}

export interface Quote {
  readonly id: string;
  readonly revision: number;
  readonly amountCents: number;
  readonly currency: 'BRL';
  readonly document: PrintFile;
  readonly decision: QuoteDecision;
  readonly rejectionReason: string | null;
  readonly submittedAt: string;
  readonly decidedAt: string | null;
}

export interface BatchSummary {
  readonly id: string;
  readonly reference: string;
  readonly status: BatchStatus;
  readonly version: number;
  readonly itemCount: number;
  readonly createdAt: string;
  readonly collectedAt: string | null;
  readonly printedAt: string | null;
  readonly receivedAt: string | null;
  readonly approvedAmountCents: number | null;
}

export interface Batch extends BatchSummary {
  readonly items: readonly BatchItem[];
  readonly currentQuote: Quote | null;
  readonly cancellationReason: string | null;
}

export interface BatchPage {
  readonly items: readonly BatchSummary[];
  readonly nextCursor: string | null;
}

/** Portuguese labels shown to the print shop. */
export const BATCH_STATUS_LABELS: Readonly<Record<BatchStatus, string>> = {
  open: 'Pronto',
  files_collected: 'Arquivos retirados',
  quote_pending: 'Aguardando aprovação do Financeiro',
  quote_rejected: 'Orçamento rejeitado',
  quote_approved: 'Orçamento aprovado',
  printed: 'Impresso',
  received: 'Recebido',
  cancelled: 'Cancelado',
};

export function isBatchStatus(value: unknown): value is BatchStatus {
  return typeof value === 'string' && (BATCH_STATUSES as readonly string[]).includes(value);
}

/** The progress bar of the current batch, in order. */
export const BATCH_PROGRESS_STEPS = [
  'Pronto',
  'Arquivos retirados',
  'Orçamento enviado',
  'Orçamento aprovado',
  'Impresso',
] as const;

/** Index of the reached step in {@link BATCH_PROGRESS_STEPS}, or -1 (received/cancelled). */
export function progressStep(status: BatchStatus): number {
  switch (status) {
    case 'open':
      return 0;
    case 'files_collected':
      return 1;
    case 'quote_pending':
    case 'quote_rejected':
      return 2;
    case 'quote_approved':
      return 3;
    case 'printed':
      return 4;
    default:
      return -1;
  }
}

/** The supplier action the UI may offer for a batch, if any. */
export type BatchAction = 'collect' | 'upload-quote' | 'mark-printed' | null;

export function availableAction(batch: Pick<Batch, 'status' | 'currentQuote'>): BatchAction {
  switch (batch.status) {
    case 'open':
      return 'collect';
    case 'files_collected':
    case 'quote_rejected':
      return 'upload-quote';
    case 'quote_approved':
      return batch.currentQuote?.decision === 'approved' ? 'mark-printed' : null;
    default:
      return null;
  }
}

/** Read-only waiting text for states where the print shop has nothing to do. */
export function waitingMessage(status: BatchStatus): string | null {
  switch (status) {
    case 'quote_pending':
      return 'Aguardando aprovação do Financeiro';
    case 'printed':
      return 'Aguardando recebimento';
    default:
      return null;
  }
}

/** Every file of an item, job files first then residual ones, with its job if paired. */
export function itemFiles(
  item: BatchItem,
): readonly { readonly file: PrintFile; readonly job: PrintJob | null }[] {
  return [
    ...item.jobs.map((job) => ({ file: job.file, job })),
    ...(item.generalInstructions?.files ?? []).map((file) => ({ file, job: null })),
  ];
}

/** Total copies to print: paired jobs only (residual files carry no copies). */
export function totalCopies(batch: Pick<Batch, 'items'>): number {
  return batch.items.reduce(
    (sum, item) => sum + item.jobs.reduce((jobs, job) => jobs + job.copies, 0),
    0,
  );
}

/** Number of file cards (downloads) in a batch. */
export function fileCount(batch: Pick<Batch, 'items'>): number {
  return batch.items.reduce((sum, item) => sum + itemFiles(item).length, 0);
}
