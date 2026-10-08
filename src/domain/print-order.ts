/**
 * Print-shop portal — order domain (spec print-portal §4.2, frozen contract
 * print-portal-v1.schema.json).
 *
 * These are the shapes the portal receives from the Incluir service API and
 * re-serves to the browser. The portal is not the authority for any of this
 * state; the pure helpers below only decide what the UI may OFFER. The
 * upstream re-checks every rule.
 */

export const ORDER_STATUSES = [
  'ready',
  'files_collected',
  'quote_pending',
  'quote_rejected',
  'quote_approved',
  'printed',
  'cancelled',
] as const;

export type OrderStatus = (typeof ORDER_STATUSES)[number];

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

export interface Quote {
  readonly id: string;
  readonly revision: number;
  readonly orderRevision: number;
  readonly amountCents: number;
  readonly currency: 'BRL';
  readonly document: PrintFile;
  readonly decision: QuoteDecision;
  readonly rejectionReason: string | null;
  readonly submittedAt: string;
  readonly decidedAt: string | null;
}

export interface OrderSummary {
  readonly id: string;
  readonly reference: string;
  readonly title: string;
  readonly revision: number;
  readonly version: number;
  readonly status: OrderStatus;
  readonly createdAt: string;
  readonly collectedAt: string | null;
  readonly printedAt: string | null;
  readonly approvedAmountCents: number | null;
}

export interface Order extends OrderSummary {
  readonly jobs: readonly PrintJob[];
  readonly currentQuote: Quote | null;
  readonly cancellationReason: string | null;
}

export interface OrderPage {
  readonly items: readonly OrderSummary[];
  readonly nextCursor: string | null;
}

/** Portuguese labels shown to the print shop. */
export const ORDER_STATUS_LABELS: Readonly<Record<OrderStatus, string>> = {
  ready: 'Pronto para retirada',
  files_collected: 'Arquivos retirados',
  quote_pending: 'Aguardando aprovação do Financeiro',
  quote_rejected: 'Orçamento rejeitado',
  quote_approved: 'Orçamento aprovado',
  printed: 'Impresso',
  cancelled: 'Cancelado',
};

export function isOrderStatus(value: unknown): value is OrderStatus {
  return typeof value === 'string' && (ORDER_STATUSES as readonly string[]).includes(value);
}

/** The supplier action the UI may offer for an order, if any (spec §3.4, §7). */
export type SupplierAction = 'collect' | 'quote' | 'print' | null;

export function availableAction(order: Pick<Order, 'status' | 'currentQuote'>): SupplierAction {
  switch (order.status) {
    case 'ready':
      return 'collect';
    case 'files_collected':
    case 'quote_rejected':
      return 'quote';
    case 'quote_approved':
      return order.currentQuote?.decision === 'approved' ? 'print' : null;
    default:
      return null;
  }
}
